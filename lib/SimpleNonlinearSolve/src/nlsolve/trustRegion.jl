"""
    SimpleTrustRegion(; autodiff = AutoForwardDiff(), max_trust_radius::Real = 0.0,
        initial_trust_radius::Real = 0.0, step_threshold::Real = 0.1,
        shrink_threshold::Real = 0.25, expand_threshold::Real = 0.75,
        shrink_factor::Real = 0.25, expand_factor::Real = 2.0, max_shrink_times::Int = 32)

A low-overhead implementation of a trust-region solver. This method is non-allocating on
scalar and static array problems.

### Keyword Arguments

  - `autodiff`: determines the backend used for the Jacobian. Defaults to
    `AutoForwardDiff()`. Valid choices are `AutoForwardDiff()` or `AutoFiniteDiff()`.
  - `max_trust_radius`: the maximum radius of the trust region. Defaults to
    `max(norm(f(u0)), maximum(u0) - minimum(u0))`.
  - `initial_trust_radius`: the initial trust region radius. Defaults to
    `max_trust_radius / 11`.
  - `step_threshold`: the threshold for taking a step. In every iteration, the threshold is
    compared with a value `r`, which is the actual reduction in the objective function divided
    by the predicted reduction. If `step_threshold > r` the model is not a good approximation,
    and the step is rejected. Defaults to `0.1`. For more details, see
    [Rahpeymaii, F.](https://link.springer.com/article/10.1007/s40096-020-00339-4)
  - `shrink_threshold`: the threshold for shrinking the trust region radius. In every
    iteration, the threshold is compared with a value `r` which is the actual reduction in the
    objective function divided by the predicted reduction. If `shrink_threshold > r` the trust
    region radius is shrunk by `shrink_factor`. Defaults to `0.25`. For more details, see
    [Rahpeymaii, F.](https://link.springer.com/article/10.1007/s40096-020-00339-4)
  - `expand_threshold`: the threshold for expanding the trust region radius. If a step is
    taken, i.e `step_threshold < r` (with `r` defined in `shrink_threshold`), a check is also
    made to see if `expand_threshold < r`. If that is true, the trust region radius is
    expanded by `expand_factor`. Defaults to `0.75`.
  - `shrink_factor`: the factor to shrink the trust region radius with if
    `shrink_threshold > r` (with `r` defined in `shrink_threshold`). Defaults to `0.25`.
  - `expand_factor`: the factor to expand the trust region radius with if
    `expand_threshold < r` (with `r` defined in `shrink_threshold`). Defaults to `2.0`.
  - `max_shrink_times`: the maximum number of times to shrink the trust region radius in a
    row, `max_shrink_times` is exceeded, the algorithm returns. Defaults to `32`.
"""
@kwdef @concrete struct SimpleTrustRegion <: AbstractNewtonAlgorithm
    autodiff = AutoForwardDiff()
    max_trust_radius = 0.0
    initial_trust_radius = 0.0
    step_threshold = 0.0001
    shrink_threshold = 0.25
    expand_threshold = 0.75
    shrink_factor = 0.25
    expand_factor = 2.0
    max_shrink_times::Int = 32
end

function SciMLBase.__solve(prob::NonlinearProblem, alg::SimpleTrustRegion, args...;
        abstol = nothing, reltol = nothing, maxiters = 1000,
        termination_condition = nothing, kwargs...)
    @bb x = copy(float(prob.u0))
    T = eltype(real(x))
    Δₘₐₓ = T(alg.max_trust_radius)
    Δ = T(alg.initial_trust_radius)
    η₁ = T(alg.step_threshold)
    η₂ = T(alg.shrink_threshold)
    η₃ = T(alg.expand_threshold)
    t₁ = T(alg.shrink_factor)
    t₂ = T(alg.expand_factor)
    max_shrink_times = alg.max_shrink_times

    fx = _get_fx(prob, x)
    @bb xo = copy(x)
    J, jac_cache = jacobian_cache(alg.autodiff, prob.f, fx, x, prob.p)
    fx, ∇f = value_and_jacobian(alg.autodiff, prob.f, fx, x, prob.p, jac_cache; J)

    abstol, reltol, tc_cache = init_termination_cache(abstol, reltol, fx, x,
        termination_condition)

    # Set default trust region radius if not specified by user.
    Δₘₐₓ == 0 && (Δₘₐₓ = max(norm(fx), maximum(x) - minimum(x)))
    Δ == 0 && (Δ = Δₘₐₓ / 11)

    fₖ = 0.5 * norm(fx)^2
    H = ∇f' * ∇f
    g = ∇f' * fx
    shrink_counter = 0

    @bb δsd = copy(x)
    @bb δN_δsd = copy(x)
    @bb δN = copy(x)
    @bb Hδ = copy(x)
    dogleg_cache = (; δsd, δN_δsd, δN)

    F = fx
    for k in 1:maxiters
        # Solve the trust region subproblem.
        δ = dogleg_method!!(dogleg_cache, ∇f, fx, g, Δ)
        @bb @. x = xo + δ

        fx = __eval_f(prob, fx, x)

        fₖ₊₁ = norm(fx)^2 / T(2)

        # Compute the ratio of the actual to predicted reduction.
        @bb Hδ = H × δ
        r = (fₖ₊₁ - fₖ) / (dot(δ', g) + dot(δ', Hδ) / T(2))

        # Update the trust region radius.
        if r < η₂
            Δ = t₁ * Δ
            shrink_counter += 1
            shrink_counter > max_shrink_times && return build_solution(prob, alg, x, fx;
                retcode = ReturnCode.ConvergenceFailure)
        else
            shrink_counter = 0
        end

        if r > η₁
            # Termination Checks
            tc_sol = check_termination(tc_cache, fx, x, xo, prob, alg)
            tc_sol !== nothing && return tc_sol

            # Take the step.
            @bb @. xo = x

            fx, ∇f = value_and_jacobian(alg.autodiff, prob.f, fx, x, prob.p, jac_cache; J)

            # Update the trust region radius.
            (r > η₃) && (norm(δ) ≈ Δ) && (Δ = min(t₂ * Δ, Δₘₐₓ))
            fₖ = fₖ₊₁

            @bb H = transpose(∇f) × ∇f
            @bb g = transpose(∇f) × fx
        end
    end

    return build_solution(prob, alg, x, fx; retcode = ReturnCode.MaxIters)
end

function dogleg_method!!(cache, J, f, g, Δ)
    (; δsd, δN_δsd, δN) = cache

    # Compute the Newton step.
    @bb δN .= J \ f
    @bb δN .*= -1
    # Test if the full step is within the trust region.
    (norm(δN) ≤ Δ) && return δN

    # Calcualte Cauchy point, optimum along the steepest descent direction.
    @bb δsd .= g
    @bb @. δsd *= -1
    norm_δsd = norm(δsd)
    if (norm_δsd ≥ Δ)
        @bb @. δsd *= Δ / norm_δsd
        return δsd
    end

    # Find the intersection point on the boundary.
    @bb @. δN_δsd = δN - δsd
    dot_δN_δsd = dot(δN_δsd, δN_δsd)
    dot_δsd_δN_δsd = dot(δsd, δN_δsd)
    dot_δsd = dot(δsd, δsd)
    fact = dot_δsd_δN_δsd^2 - dot_δN_δsd * (dot_δsd - Δ^2)
    tau = (-dot_δsd_δN_δsd + sqrt(fact)) / dot_δN_δsd
    @bb @. δsd += tau * δN_δsd
    return δsd
end
