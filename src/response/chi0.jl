using LinearMaps

@doc raw"""
Compute the independent-particle susceptibility. Will blow up for large systems.
For non-spin-polarized calculations the matrix dimension is
`prod(basis.fft_size)` × `prod(basis.fft_size)` and
for collinear spin-polarized cases it is
`2prod(basis.fft_size)` × `2prod(basis.fft_size)`.
In this case the matrix has effectively 4 blocks, which are:
```math
\left(\begin{array}{cc}
    (χ_0)_{αα}  & (χ_0)_{αβ} \\
    (χ_0)_{βα}  & (χ_0)_{ββ}
\end{array}\right)
```
"""
function compute_χ0(ham; temperature=ham.basis.model.temperature)
    # We're after χ0(r,r') such that δρ = ∫ χ0(r,r') δV(r') dr'
    # where (up to normalizations)
    # ρ = ∑_nk f(εnk - εF) |ψnk|^2
    # ∑_nk f(εnk - εF) = N_el
    # Everything is summed on k so we omit it for notational simplicity

    # We differentiate wrt a variation δV of the external potential
    # δρ = ∑_n (f'n δεn |ψn|^2 + 2Re fn ψn* δψn - f'n δεF |ψn|^2
    # with fn = f(εnk - εF), f'n = f'(εnk - εF)
    # δN_el = 0 = ∑_n f'n (δεn - δεF)

    # Now we use from first order perturbation theory
    # δεn = <ψn|δV|ψn>
    # δψn = ∑_{m != n} <ψm|δV|ψn> |ψm> / (εn-εm)

    # for δεF we get, with DOS = -∑_n f'n and LDOS = -∑_n f'n |ψn|^2
    # δεF = 1/DOS ∫ δV(r) LDOS(r)dr

    # for δρ we note ρnm = ψn* ψm, and we get
    # δρ = LDOS δεF + ∑_n f'n <ρn|δV> ρn + ∑_{n,m != n} 2Re fn ρnm <ρmn|δV> / (εn-εm)
    # δρ = LDOS δεF + ∑_n f'n <ρn|δV> ρn + ∑_{n,m != n} (fn-fm)/(εn-εm) ρnm <ρnm|δV>
    # The last two terms merge with the convention that (f(x)-f(x))/(x-x) = f'(x) into
    # δρ = LDOS δεF + ∑_{n,m} (fn-fm) ρnm <ρmn|δV> / (εn-εm)
    # Therefore the kernel is LDOS(r) LDOS(r') / DOS + ∑_{n,m} (fn-fm)/(εn-εm) ρnm(r) ρmn(r')
    basis = ham.basis
    filled_occ = filled_occupation(basis.model)
    smearing = basis.model.smearing
    n_spin = basis.model.n_spin_components
    n_fft = prod(basis.fft_size)
    fermialg = default_fermialg(smearing)

    length(basis.model.symmetries) == 1 || error("Disable symmetries for computing χ0")

    EVs = [eigen(Hermitian(Array(Hk))) for Hk in ham.blocks]
    Es = [EV.values for EV in EVs]
    Vs = [EV.vectors for EV in EVs]
    T = eltype(basis)
    occupation, εF = compute_occupation(basis, Es, fermialg; temperature, tol_n_elec=10eps(T))

    χ0 = zeros_like(basis.G_vectors, T, n_spin * n_fft, n_spin * n_fft)
    for (ik, kpt) in enumerate(basis.kpoints)
        # The sum-over-states terms of χ0 are diagonal in the spin blocks (no αβ / βα terms)
        # so the spin of the kpt selects the block we are in
        spinrange = kpt.spin == 1 ? (1:n_fft) : (n_fft+1:2n_fft)
        χ0σσ = @view χ0[spinrange, spinrange]

        N = length(G_vectors(basis, basis.kpoints[ik]))
        @assert N < 10_000
        E = Es[ik]
        V = Vs[ik]
        Vr = cat(ifft.(Ref(basis), Ref(kpt), eachcol(V))..., dims=4)
        Vr = reshape(Vr, n_fft, N)
        for m = 1:N, n = 1:N
            enred = (E[n] - εF) / temperature
            @assert occupation[ik][n] ≈ filled_occ * Smearing.occupation(smearing, enred)
            ddiff = Smearing.occupation_divided_difference
            ratio = filled_occ * ddiff(smearing, E[m], E[n], εF, temperature)
            # dvol because inner products have a dvol in them
            # so that the dual gets one : |f> -> <dvol f|
            # can take the real part here because the nm term is complex conjugate of mn
            # TODO optimize this a bit... use symmetry nm, reduce allocs, etc.
            factor = basis.kweights[ik] * ratio * basis.dvol

            @views χ0σσ .+= factor .* real(conj((Vr[:, m] .* Vr[:, m]'))
                                           .*
                                           (Vr[:, n] .* Vr[:, n]'))
        end
    end
    mpi_sum!(χ0, basis.comm_kpts)

    # Add variation wrt εF (which is not diagonal wrt. spin)
    if temperature > 0
        dos = compute_dos(εF, basis, Es)
        ldos = compute_ldos(εF, basis, Es, Vs)
        χ0 .+= vec(ldos) .* vec(ldos)' .* basis.dvol ./ sum(dos)
    end
    χ0
end


# make ldiv! act as a given function
struct FunctionPreconditioner{T}
    precondition!::T  # precondition!(y, x) applies f to x and puts it into y
end
LinearAlgebra.ldiv!(y::T, P::FunctionPreconditioner, x) where {T} = P.precondition!(y, x)::T
LinearAlgebra.ldiv!(P::FunctionPreconditioner, x) = (x .= P.precondition!(similar(x), x))
precondprep!(P::FunctionPreconditioner, ::Any) = P

# Solves (1-P) (H-ε) (1-P) δψn = - (1-P) rhs
# where 1-P is the projector on the orthogonal of ψk
# /!\ It is assumed (and not checked) that ψk'Hk*ψk = Diagonal(εk) (extra states
# included).
function sternheimer_solver(Hk, ψk, ε, rhs;
    callback=identity, cg_callback=identity,
    ψk_extra=zeros_like(ψk, size(ψk, 1), 0), εk_extra=zeros(0),
    Hψk_extra=zeros_like(ψk, size(ψk, 1), 0), tol=1e-9)
    basis = Hk.basis
    kpoint = Hk.kpoint

    # We use a Schur decomposition of the orthogonal of the occupied states
    # into a part where we have the partially converged, non-occupied bands
    # (which are Rayleigh-Ritz wrt to Hk) and the rest.

    # Projectors:
    # projector onto the computed and converged states
    P(ϕ) = ψk * (ψk' * ϕ)
    # projector onto the computed but nonconverged states
    P_extra(ϕ) = ψk_extra * (ψk_extra' * ϕ)
    # projector onto the computed (converged and unconverged) states
    P_computed(ϕ) = P(ϕ) + P_extra(ϕ)
    # Q = 1-P is the projector onto the orthogonal of converged states
    Q(ϕ) = ϕ - P(ϕ)
    # R = 1-P_computed is the projector onto the orthogonal of computed states
    R(ϕ) = ϕ - P_computed(ϕ)

    # We put things into the form
    # δψkn = ψk_extra * αkn + δψknᴿ ∈ Ran(Q)
    # where δψknᴿ ∈ Ran(R).
    # Note that, if ψk_extra = [], then 1-P = 1-P_computed and
    # δψkn = δψknᴿ is obtained by inverting the full Sternheimer
    # equations in Ran(Q) = Ran(R)
    #
    # This can be summarized as the following:
    #
    # <---- P ----><------------ Q = 1-P -----------------
    #              <-- P_extra -->
    # <--------P_computed -------><-- R = 1-P_computed ---
    # |-----------|--------------|------------------------
    # 1     N_occupied  N_occupied + N_extra

    # ψk_extra are not converged but have been Rayleigh-Ritzed (they are NOT
    # eigenvectors of H) so H(ψk_extra) = ψk_extra' (Hk-ε) ψk_extra should be a
    # real diagonal matrix.
    H(ϕ) = Hk * ϕ - ε * ϕ
    ψk_exHψk_ex = Diagonal(real.(εk_extra .- ε))

    # 1) solve for δψknᴿ
    # ----------------------------
    # writing αkn as a function of δψknᴿ, we get that δψknᴿ
    # solves the system (in Ran(1-P_computed))
    #
    # R * (H - ε) * (1 - M * (H - ε)) * R * δψknᴿ = R * (1 - M) * b
    #
    # where M = ψk_extra * (ψk_extra' (H-ε) ψk_extra)^{-1} * ψk_extra'
    # is defined above and b is the projection of -rhs onto Ran(Q).
    #
    b = -Q(rhs)
    bb = R(b - Hψk_extra * (ψk_exHψk_ex \ ψk_extra'b))
    function RAR(ϕ)
        Rϕ = R(ϕ)
        # Schur complement of (1-P) (H-ε) (1-P)
        # with the splitting Ran(1-P) = Ran(P_extra) ⊕ Ran(R)
        R(H(Rϕ) - Hψk_extra * (ψk_exHψk_ex \ Hψk_extra'Rϕ))
    end
    precon = PreconditionerTPA(basis, kpoint)
    # First column of ψk as there is no natural kinetic energy.
    # We take care of the (rare) cases when ψk is empty.
    precondprep!(precon, size(ψk, 2) ≥ 1 ? ψk[:, 1] : nothing)
    function R_ldiv!(x, y)
        x .= R(precon \ R(y))
    end
    J = LinearMap{eltype(ψk)}(RAR, size(Hk, 1))
    res = cg(J, bb; precon=FunctionPreconditioner(R_ldiv!), tol, proj=R,
        callback=cg_callback)
    #res = cg(J, bb; tol=tol, proj=R, callback=cg_callback)
    !res.converged && @warn("Sternheimer CG not converged", res.n_iter,
        res.tol, res.residual_norm)
    δψknᴿ = res.x
    info = (; basis, kpoint, res)
    callback(info)

    # 2) solve for αkn now that we know δψknᴿ
    # Note that αkn is an empty array if there is no extra bands.
    αkn = ψk_exHψk_ex \ ψk_extra' * (b - H(δψknᴿ))

    δψkn = ψk_extra * αkn + δψknᴿ
end

# Apply the four-point polarizability operator χ0_4P = -Ω^-1
# Returns (δψ, δocc, δεF) corresponding to a change in *total* Hamiltonian δH
# We start from
# P = f(H-εF) = ∑_n fn |ψn><ψn|, tr(P) = N
# where P is the density matrix, f the occupation function.
# Charge conservation yields δεF as follows:
# δεn = <ψn|δH|ψn>
# 0 = ∑_n fn' (δεn - δεF) determines δεF
# where fn' = f'((εn-εF)/T)/T.

# Then <ψm|δP|ψn> = (fm-fn)/(εm-εn) <ψm|δH|ψn>,
# except for the diagonal which is
# <ψn|δP|ψn> = (fn'-δεF) δεn.

# We want to represent δP with a tuple (δψ, δf). We do *not* impose that
# δψ is orthogonal at finite temperature. A formal differentiation yields
# δP = ∑_n fn (|δψn><ψn| + |ψn><δψn|) + δfn |ψn><ψn|.
# Identifying with <ψm|δP|ψn> we get for the off-diagonal terms
# (fm-fn)/(εm-εn) <ψm|δH|ψn> = fm <δψm|ψn> + fn <ψm|δψn>.
# For the diagonal terms, n==m and we obtain
# 0 = ∑_n Re (fn <ψn|δψn>) + δfn,
# so that a gauge choice has to be made here. We choose to set <ψn|δψn> = 0 and
# δfn = fn' (δεn - δεF) ensures the summation to 0 with the definition of δεF as
# above.

# We therefore need to compute all the δfn: this is done with compute_δocc!.
# Regarding the δψ, they are computed with compute_δψ! as follows. We refer to
# the paper https://arxiv.org/abs/2210.04512 for more details.

# We split the computation of δψn in two contributions:
# for the already-computed states, we add an explicit contribution
# for the empty states, we solve a Sternheimer equation
# (H-εn) δψn = - P_{ψ^⟂} δH ψn

# The off-diagonal explicit term needs a careful consideration of stability.
# Let <ψm|δψn> = αmn <ψm|δH|ψn>. αmn has to satisfy
# fn αmn + fm αnm = ratio = (fn-fm)/(εn-εm)   (*)
# The usual way is to impose orthogonality (=> αmn=-αnm),
# but this means that αmn = 1/(εm-εn), which is unstable
# Instead, we minimize αmn^2 + αnm^2 under the linear constraint (*), which leads to
# αmn = ratio * fn / (fn^2 + fm^2)
# fn αmn = ratio * fn^2 / (fn^2 + fm^2)

# This formula is very nice
# - It gives a vanishing contribution fn αmn for empty states
#   (note that α itself blows up, but it's compensated by fn)
# - In the case where fn=1/0 or fm=0 we recover the same formulas
#   as the ones with orthogonality
# - When n=m it gives the correct contribution
# - It does not blow up for degenerate states
function compute_αmn(fm, fn, ratio)
    ratio == 0 && return ratio
    ratio * fn / (fn^2 + fm^2)
end

"""
Compute the derivatives of the occupations (and of the Fermi level).
The derivatives of the occupations are in-place stored in δocc.
The tuple (; δocc, δεF) is returned. It is assumed the passed `δocc`
are initialised to zero.
"""
function compute_δocc!(δocc, basis::PlaneWaveBasis{T}, ψ, εF, ε, δHψ) where {T}
    model = basis.model
    temperature = model.temperature
    smearing = model.smearing
    filled_occ = filled_occupation(model)
    Nk = length(basis.kpoints)

    # δocc = fn' * (δεn - δεF)
    δεF = zero(T)
    if temperature > 0
        # First compute δocc without self-consistent Fermi δεF.
        D = zero(T)
        for ik = 1:Nk, (n, εnk) in enumerate(ε[ik])
            enred = (εnk - εF) / temperature
            δεnk = real(dot(ψ[ik][:, n], δHψ[ik][:, n]))
            fpnk = filled_occ * Smearing.occupation_derivative(smearing, enred) / temperature
            δocc[ik][n] = δεnk * fpnk
            D += fpnk * basis.kweights[ik]
        end
        # Compute δεF…
        D = mpi_sum(D, basis.comm_kpts)  # equal to minus the total DOS
        δocc_tot = mpi_sum(sum(basis.kweights .* sum.(δocc)), basis.comm_kpts)
        δεF = !isnothing(model.εF) ? zero(δεF) : δocc_tot / D  # no δεF when Fermi level is fixed
        # … and recompute δocc, taking into account δεF.
        for ik = 1:Nk, (n, εnk) in enumerate(ε[ik])
            enred = (εnk - εF) / temperature
            fpnk = filled_occ * Smearing.occupation_derivative(smearing, enred) / temperature
            δocc[ik][n] -= fpnk * δεF
        end
    end

    (; δocc, δεF)
end

"""
Perform in-place computations of the derivatives of the wave functions by solving
a Sternheimer equation for each `k`-points. It is assumed the passed `δψ` are initialised
to zero.
For phonon, `δHψ[ik]` is ``δH·ψ_{k-q}``, expressed in `basis.kpoints[ik]`.
"""
function compute_δψ!(δψ, basis::PlaneWaveBasis{T}, H, ψ, εF, ε, δHψ, ε_minus_q=ε;
    ψ_extra=[zeros_like(ψk, size(ψk, 1), 0) for ψk in ψ], q=zero(Vec3{T}),
    CG_tol_scale=nothing, kwargs_sternheimer...) where {T}
    # We solve the Sternheimer equation
    #   (H_k - ε_{n,k-q}) δψ_{n,k} = - (1 - P_{k}) δHψ_{n, k-q},
    # where P_{k} is the projector on ψ_{k} and with the conventions:
    # * δψ_{k} is the variation of ψ_{k-q}, which implies (for ℬ_{k} the `basis.kpoints`)
    #     δψ_{k-q} ∈ ℬ_{k-q} and δHψ_{k-q} ∈ ℬ_{k};
    # * δHψ[ik] = δH ψ_{k-q};
    # * ε_minus_q[ik] = ε_{·, k-q}.
    model = basis.model
    temperature = model.temperature
    smearing = model.smearing
    filled_occ = filled_occupation(model)

    flag = !isnothing(CG_tol_scale)
    #flag = false
    if flag
        tol_sternheimer = kwargs_sternheimer[:tol]
    end
    # Compute δψnk band per band
    for ik = 1:length(ψ)
        Hk = H[ik]
        ψk = ψ[ik]
        εk = ε[ik]
        δψk = δψ[ik]
        εk_minus_q = ε_minus_q[ik]

        ψk_extra = ψ_extra[ik]
        Hψk_extra = Hk * ψk_extra
        εk_extra = diag(real.(ψk_extra' * Hψk_extra))
        for n = 1:length(εk_minus_q)
            fnk_minus_q = filled_occ * Smearing.occupation(smearing, (εk_minus_q[n] - εF) / temperature)

            # Explicit contributions (nonzero only for temperature > 0)
            for m = 1:length(εk)
                # The n == m contribution in compute_δρ is obtained through δoccupation, see
                # the explanation above; except if we perform phonon calculations.
                iszero(q) && (m == n) && continue
                fmk = filled_occ * Smearing.occupation(smearing, (εk[m] - εF) / temperature)
                ddiff = Smearing.occupation_divided_difference
                ratio = filled_occ * ddiff(smearing, εk[m], εk_minus_q[n], εF, temperature)
                αmn = compute_αmn(fmk, fnk_minus_q, ratio)  # fnk_minus_q * αmn + fmk * αnm = ratio
                δψk[:, n] .+= ψk[:, m] .* αmn .* dot(ψk[:, m], δHψ[ik][:, n])
            end

            # Sternheimer contribution with adaptive CG tolerance
            if flag
                kwargs_sternheimer = merge(kwargs_sternheimer, Dict(:tol => tol_sternheimer / CG_tol_scale[ik][n]))
            end
            # do not use tol smaller than eps(T)/2
            kwargs_sternheimer = merge(kwargs_sternheimer, Dict(:tol => max(0.5*eps(T), kwargs_sternheimer[:tol])))
            δψk[:, n] .+= sternheimer_solver(Hk, ψk, εk_minus_q[n], δHψ[ik][:, n]; ψk_extra,
                εk_extra, Hψk_extra, kwargs_sternheimer...)

            # do not use schur trick
            #δψk[:, n] .+= sternheimer_solver(Hk, ψk, εk_minus_q[n], δHψ[ik][:, n];kwargs_sternheimer...)
        end
    end
end

@views @timing function apply_χ0_4P(ham, ψ, occupation, εF, eigenvalues, δHψ;
    occupation_threshold, q=zero(Vec3{eltype(ham.basis)}),
    kwargs_sternheimer...)
    basis = ham.basis
    k_to_k_minus_q = k_to_kpq_permutation(basis, -q)

    # We first select orbitals with occupation number higher than
    # occupation_threshold for which we compute the associated response δψn,
    # the others being discarded to ψ_extra.
    # We then use the extra information we have from these additional bands,
    # non-necessarily converged, to split the Sternheimer_solver with a Schur
    # complement.
    occ_thresh = occupation_threshold
    mask_occ = map(occk -> findall(occnk -> abs(occnk) ≥ occ_thresh, occk), occupation)
    mask_extra = map(occk -> findall(occnk -> abs(occnk) < occ_thresh, occk), occupation)

    ψ_occ = [ψ[ik][:, maskk] for (ik, maskk) in enumerate(mask_occ)]
    ψ_extra = [ψ[ik][:, maskk] for (ik, maskk) in enumerate(mask_extra)]
    ε_occ = [eigenvalues[ik][maskk] for (ik, maskk) in enumerate(mask_occ)]
    δHψ_minus_q_occ = [δHψ[ik][:, mask_occ[k_to_k_minus_q[ik]]] for ik = 1:length(basis.kpoints)]
    # Only needed for phonon calculations.
    ε_minus_q_occ = [eigenvalues[k_to_k_minus_q[ik]][mask_occ[k_to_k_minus_q[ik]]]
                     for ik = 1:length(basis.kpoints)]

    # First we compute δoccupation. We only need to do this for the actually occupied
    # orbitals. So we make a fresh array padded with zeros, but only alter the elements
    # corresponding to the occupied orbitals. (Note both compute_δocc! and compute_δψ!
    # assume that the first array argument has already been initialised to zero).
    # For phonon calculations when q ≠ 0, we do not use δoccupation, and compute directly
    # the full perturbation δψ.
    δoccupation = zero.(occupation)
    if iszero(q)
        δocc_occ = [δoccupation[ik][maskk] for (ik, maskk) in enumerate(mask_occ)]
        (; δεF) = compute_δocc!(δocc_occ, basis, ψ_occ, εF, ε_occ, δHψ_minus_q_occ)
    else
        # When δH is not periodic, δH ψnk is a Bloch wave at k+q and ψnk at k,
        # so that δεnk = <ψnk|δH|ψnk> = 0 and there is no occupation shift
        δεF = zero(εF)
    end

    # Then we compute δψ (again in-place into a zero-padded array) with elements of
    # `basis.kpoints` that are equivalent to `k+q`.
    δψ = zero.(δHψ)
    δψ_occ = [δψ[ik][:, maskk] for (ik, maskk) in enumerate(mask_occ[k_to_k_minus_q])]
    compute_δψ!(δψ_occ, basis, ham.blocks, ψ_occ, εF, ε_occ, δHψ_minus_q_occ, ε_minus_q_occ;
        ψ_extra, q, kwargs_sternheimer...)

    (; δψ, δoccupation, δεF)
end

function get_apply_χ0_info(ham, ψ, occupation, εF::T, eigenvalues;
    occupation_threshold=default_occupation_threshold(T),
    q=zero(Vec3{eltype(ham.basis)}),CG_tol_type="hdmd") where {T}

    CG_tol_type = lowercase(string(CG_tol_type))

    basis = ham.basis
    num_kpoints = length(basis.kpoints)
    k_to_k_minus_q = k_to_kpq_permutation(basis, -q)

    mask_occ = map(occk -> findall(occnk -> abs(occnk) ≥ occupation_threshold, occk), occupation)
    mask_extra = map(occk -> findall(occnk -> abs(occnk) < occupation_threshold, occk), occupation)

    ψ_occ = [ψ[ik][:, maskk] for (ik, maskk) in enumerate(mask_occ)]
    ψ_extra = [ψ[ik][:, maskk] for (ik, maskk) in enumerate(mask_extra)]
    ε_occ = [eigenvalues[ik][maskk] for (ik, maskk) in enumerate(mask_occ)]

    ε_minus_q_occ = [eigenvalues[k_to_k_minus_q[ik]][mask_occ[k_to_k_minus_q[ik]]]
                     for ik = 1:num_kpoints]

    Nocc_ks = [length(ε_occ[ik]) for ik in 1:num_kpoints]
    Nocc = sum(Nocc_ks)

    # compute CG_tol_scale
    fn_occ = [occupation[ik][maskk] for (ik, maskk) in enumerate(mask_occ)]
    if CG_tol_type == "hdmd"
        CG_tol_scale = [fn_occ[ik] * basis.kweights[ik] for ik in 1:num_kpoints] * Nocc * sqrt(prod(basis.fft_size)) / basis.model.unit_cell_volume
    elseif CG_tol_type == "grt"
        kcoef = zeros(num_kpoints)
        for k in 1:num_kpoints
        accum = zeros(basis.fft_size)
        for n in 1:Nocc_ks[k]
            accum += (abs2.(real.(ifft(basis, basis.kpoints[k], ψ[k][:, n]))))
        end
        kcoef[k] = sqrt(maximum(accum)) * basis.kweights[k]
        end

        CG_tol_scale = [fn_occ[ik] * kcoef[ik] for ik in 1:num_kpoints] * sqrt(Nocc) * sqrt(prod(basis.fft_size)) / sqrt(basis.model.unit_cell_volume)
    else
        CG_tol_scale = [[1.0 for _ in 1:Nocc_ks[ik]] for ik in 1:num_kpoints]
        if !occursin(CG_tol_type, "agrplain1.0")
            @warn("CG_tol_type is not recognized, set CG_tol_scale to 1.0 for all bands")
        end
    end

    (; k_to_k_minus_q, mask_occ, ψ_occ, ψ_extra, ε_occ, ε_minus_q_occ, CG_tol_scale)
end

@views @timing function apply_χ0_4P(ham, occupation, εF, δHψ, apply_χ0_info::NamedTuple;
    q=zero(Vec3{eltype(ham.basis)}), kwargs_sternheimer...)


    # ψ_occ   = apply_χ0_info.ψ_occ
    # ψ_extra = apply_χ0_info.ψ_extra
    # ε_occ   = apply_χ0_info.ε_occ
    # δHψ_minus_q_occ = apply_χ0_info.δHψ_minus_q_occ
    # ε_minus_q_occ  = apply_χ0_info.ε_minus_q_occ
    # δoccupation = apply_χ0_info.δoccupation
    # δεF = apply_χ0_info.δεF
    basis = ham.basis
    mask_occ = apply_χ0_info.mask_occ
    k_to_k_minus_q = apply_χ0_info.k_to_k_minus_q
    ψ_occ = apply_χ0_info.ψ_occ
    ε_occ = apply_χ0_info.ε_occ

    δHψ_minus_q_occ = [δHψ[ik][:, mask_occ[k_to_k_minus_q[ik]]] for ik = 1:length(basis.kpoints)]

    δoccupation = zero.(occupation)
    if iszero(q)
        δocc_occ = [δoccupation[ik][maskk] for (ik, maskk) in enumerate(mask_occ)]
        (; δεF) = compute_δocc!(δocc_occ, basis, ψ_occ, εF, ε_occ, δHψ_minus_q_occ)
    else
        # When δH is not periodic, δH ψnk is a Bloch wave at k+q and ψnk at k,
        # so that δεnk = <ψnk|δH|ψnk> = 0 and there is no occupation shift
        δεF = zero(εF)
    end

    # Then we compute δψ (again in-place into a zero-padded array) with elements of
    # `basis.kpoints` that are equivalent to `k+q`.
    δψ = zero.(δHψ)
    δψ_occ = [δψ[ik][:, maskk] for (ik, maskk) in enumerate(mask_occ[k_to_k_minus_q])]
    compute_δψ!(δψ_occ, ham.basis, ham.blocks, ψ_occ, εF, ε_occ, δHψ_minus_q_occ, apply_χ0_info.ε_minus_q_occ;
        apply_χ0_info.ψ_extra, q, apply_χ0_info.CG_tol_scale, kwargs_sternheimer...)

    (; δψ, δoccupation, δεF)
end

"""
Get the density variation δρ corresponding to a potential variation δV.
"""
function apply_χ0(ham, ψ, occupation, εF::T, eigenvalues, δV::AbstractArray{TδV};
    occupation_threshold=default_occupation_threshold(TδV), q=zero(Vec3{eltype(ham.basis)}),
    apply_χ0_info=nothing, kwargs_sternheimer...) where {T,TδV}

    basis = ham.basis

    # Make δV respect the basis symmetry group, since we won't be able
    # to compute perturbations that don't anyway
    δV = symmetrize_ρ(basis, δV)

    # Normalize δV to avoid numerical trouble; theoretically should
    # not be necessary, but it simplifies the interaction with the
    # Sternheimer linear solver (it makes the rhs be order 1 even if
    # δV is small)
    normδV = norm(δV)
    normδV < eps(T) && return zero(δV)
    δV ./= normδV

    # For phonon calculations, assemble
    #   δHψ_k = δV_{q} · ψ_{k-q}.
    δHψ = multiply_ψ_by_blochwave(basis, ψ, δV, q)
    if isnothing(apply_χ0_info)
        (; δψ, δoccupation) = apply_χ0_4P(ham, ψ, occupation, εF, eigenvalues, δHψ;
            occupation_threshold, q, kwargs_sternheimer...)
    else
        (; δψ, δoccupation) = apply_χ0_4P(ham, occupation, εF, δHψ, apply_χ0_info;
            q, kwargs_sternheimer...)
    end

    δρ = compute_δρ(basis, ψ, δψ, occupation, δoccupation; occupation_threshold, q)

    δρ * normδV
end

function apply_χ0(scfres, δV; apply_χ0_info=nothing, kwargs_sternheimer...)
    apply_χ0(scfres.ham, scfres.ψ, scfres.occupation, scfres.εF, scfres.eigenvalues, δV;
        occupation_threshold=scfres.occupation_threshold,
        apply_χ0_info=apply_χ0_info, kwargs_sternheimer...)
end
