"""
    AbstractPreprocess{F}

Abstract supertype for preprocessing wrappers. Subtypes wrap a function `f` and mark it as a
preprocessing step that the scheduler resolves before the actual computation.

See also [`Preprocess`](@ref).
"""
abstract type AbstractPreprocess{F} end

"""
    Preprocess(f)
    Preprocess{false}(f)

Wrap a function `f` to mark it as a preprocessing step. When called by the scheduler, the
wrapped function receives a [`Preprocessing`](@ref) sentinel as its first argument.

`Preprocess(f)` (equivalently `Preprocess{true}(f)`) creates an "early" preprocessing step.
`Preprocess{false}(f)` creates a "late" preprocessing step, which runs after early ones.

See also [`AbstractPreprocess`](@ref), [`Preprocessing`](@ref).
"""
struct Preprocess{E,F} <: AbstractPreprocess{F}
	f::F
end
Preprocess(f::F) where F = Preprocess{true,F}(f)
Preprocess{E}(f::F) where {E,F} = Preprocess{E,F}(f)

ReproducibleJobs.is_preprocessing(::AbstractPreprocess) = true
# Base.show(io::IO, p::AbstractPreprocess{F}) where F = print(io, p.f)
Base.show(io::IO, p::T) where T<:AbstractPreprocess{F} where F = print(io, nameof(T), '(', p.f, ')')

Base.show(io::IO, p::Preprocess{E,F}) where {E,F} = print(io, "Preprocess", E ? "" : "{false}", '(', p.f, ')')


"""
    Preprocessing{E}

Sentinel type passed as the first argument to preprocessing functions. The type parameter `E`
is `true` for early preprocessing and `false` for late preprocessing.
"""
struct Preprocessing{E} end

function (p::Preprocess{E,F})(args...; kwargs...) where {E,F}
	p.f(Preprocessing{E}(), args...; kwargs...)
end


# Why is this needed? Probably because of SingletonType.
function StableHashTraits.transformer(::Type{T}) where T<:AbstractPreprocess
	# include name of T to distinguish between different AbstractPreprocess instances with the same function
	StableHashTraits.Transformer(x->(nameof(T), x.f))
end

function StableHashTraits.transformer(::Type{T}) where T<:Preprocess{E} where E
	StableHashTraits.Transformer(x->(nameof(T), E, x.f))
end



# Hmm. Can we simplify these rules? Maybe by having a `Callable{F}` to contrast to `AbstractPreprocess{F}`.
should_forward_child(::Preprocess{false}, ::Preprocess{true}) = true
should_forward_child(::AbstractPreprocess, ::Preprocess{true}) = true
should_forward_child(::Preprocess{false}, ::AbstractPreprocess) = true
should_forward_child(::Any, ::AbstractPreprocess) = true
# should_forward_child(::Any, ::Preprocess{true}) = true
should_forward_child(::Any, ::Any) = true

should_forward_child(::AbstractPreprocess, ::AbstractPreprocess) = false
should_forward_child(::AbstractPreprocess, ::Any) = false
