abstract type AbstractPreprocess{F} end

# E is a Bool type parameter which is true if the preprocess should be early, i.e. done before any other processing
struct Preprocess{E,F} <: AbstractPreprocess{F}
	f::F
end
Preprocess(f::F) where F = Preprocess{true,F}(f)
Preprocess{E}(f::F) where {E,F} = Preprocess{E,F}(f)

ReproducibleJobs.is_preprocessing(::AbstractPreprocess) = true
Base.show(io::IO, p::AbstractPreprocess{F}) where F = print(io, p.f)


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
