struct ProcessingException{T} <: Exception
	inner::T
	inner_backtrace::Vector{Base.StackTraces.StackFrame}
	stack::Vector{Spec}
end
ProcessingException(spec::Spec, inner::Exception, backtrace) = ProcessingException(inner, backtrace, [spec])

function ProcessingException(spec::Spec, causes::AbstractVector)
	# Somehow choose one of the exceptions in `causes` in a stable manner
	chosen = first(causes)
	depth = typemax(Int)
	message = nothing

	for e in causes
		d = e isa ProcessingException ? length(e.stack)	: 0
		if d <= depth
			depth = d
			m = e isa ProcessingException ? string(get_versioned_function(first(e.stack))) : string(e)
			if message === nothing || m < message
				message = m
				chosen = e
			end
		end
	end
	ProcessingException(chosen.inner, chosen.inner_backtrace, vcat(chosen.stack, spec))
end

manage(e::ProcessingException) = e # Already managed


function Base.showerror(io::IO, e::ProcessingException{T}) where T
	println(io, "ProcessingException ")
	Base.showerror(io, e.inner)
	println(io)
	println(io, "Spec stacktrace:")
	for (i,s) in enumerate(e.stack)
		println(io, " [", i, "] ", get_versioned_function(s))
	end
	print(io, "Original:")
	Base.show_backtrace(io, e.inner_backtrace)
	println(io)
end

Base.show(io::IO, e::ProcessingException) = Base.showerror(io, e)
