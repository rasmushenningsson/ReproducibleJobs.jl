abstract type AbstractPreprocess{F} end

struct Preprocess{F} <: AbstractPreprocess{F}
	f::F
end

ReproducibleJobs.is_preprocessing(::AbstractPreprocess) = true
Base.show(io::IO, p::AbstractPreprocess{F}) where F = print(io, p.f)

function (p::Preprocess{F})(args...; kwargs...) where F
	p.f(args...; kwargs...)
end


# Why is this needed? Probably because of SingletonType.
function StableHashTraits.transformer(::Type{T}) where T<:AbstractPreprocess
	# include name of T to distinguish between just `f` and different AbstractPreprocess types
	StableHashTraits.Transformer(x->(nameof(T), x.f))
end
