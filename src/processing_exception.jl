struct ProcessingException{T} <: Exception
	inner::T
	inner_backtrace::Vector{Base.StackTraces.StackFrame}
	stack::Vector{SpecArgs}
end
ProcessingException(sa::SpecArgs, inner::Exception, backtrace) = ProcessingException(inner, backtrace, [sa])

function ProcessingException(sa::SpecArgs, causes::AbstractVector)
	# Somehow choose one of the exceptions in `causes` in a stable manner
	chosen = first(causes)
	depth = typemax(Int)
	message = nothing

	for e in causes
		d = e isa ProcessingException ? length(e.stack)	: 0
		if d <= depth
			depth = d
			m = e isa ProcessingException ? string(first(e.stack).f) : string(e)
			if message === nothing || m < message
				message = m
				chosen = e
			end
		end
	end
	ProcessingException(chosen.inner, chosen.inner_backtrace, vcat(chosen.stack, sa))
end


function Base.showerror(io::IO, e::ProcessingException{T}) where T
	println(io, "ProcessingException ")
	Base.showerror(io, e.inner)
	println(io)
	println(io, "Spec stacktrace:")
	for (i,s) in enumerate(e.stack)
		println(io, " [", i, "] ", s.f)
	end
	print(io, "Original:")
	Base.show_backtrace(io, e.inner_backtrace)
	println(io)
end

Base.show(io::IO, e::ProcessingException) = Base.showerror(io, e)
