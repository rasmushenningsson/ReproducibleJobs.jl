struct Preprocess{F}
	f::F
end

ReproducibleJobs.is_preprocessing(::Preprocess) = true
Base.show(io::IO, p::Preprocess{F}) where F = print(io, p.f)

function (p::Preprocess{F})(args...; kwargs...) where F
	p.f(args...; kwargs...)
end
