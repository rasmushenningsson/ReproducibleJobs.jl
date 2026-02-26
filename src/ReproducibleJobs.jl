module ReproducibleJobs

using StableHashTraits
using ReadOnlyArrays
using Scratch: @get_scratch!
using JLD2: JLD2, jldopen, load, ZstdFilter
import AbstractTrees # for pretty printing
using SHA
import Dates # for printing of timestamped paths

using LinearAlgebra # For handling copy_arg(transposed)

using DataFrames # TODO: Use package extension?
using SparseArrays # TODO: Use package extension?

using StyledStrings # For Spec printing

export
	Deduplicator,
	Spec,
	Job,
	CompoundResult,
	AbstractPreprocess,
	Preprocess,
	TimestampedFilePath,
	ChecksummedFilePath,
	unmanage,
	deduplicate!,
	print_spec,
	fetch!,
	forward!,
	forward,
	forward_once!,
	forward_once,
	fetched,
	prefetched,
	forwarded,
	ifelse_job,
	error_job,
	checksummedfilepath_spec

# Use public keyword in Julia versions where it is available
if VERSION >= v"1.11.0-DEV.469"
	let str = """
		public
			Preprocessing,
			unsafe_unmanage,
			create_spec,
			cached
		"""
		eval(Meta.parse(str))
	end
end

include("Deduplicators/Deduplicators.jl")
using .Deduplicators
using .Deduplicators: ROArray, ROVec, ROMat


# TODO: Revise this approach
let deduplicator_singleton = Deduplicator()
	global default_deduplicator() = deduplicator_singleton
end



# include("read_only.jl")
# include("managed.jl")
# include("kwarg_vector.jl")
# include("nested.jl")

# include("hash.jl")
# include("deduplicator.jl")

# include("arg_processing.jl")
include("spec.jl")
include("spec_meta.jl")
include("preprocess.jl")
# include("compound_result.jl")
# include("cache.jl")
include("job.jl")
include("processing_exception.jl")
include("scheduler.jl")

include("paths.jl")

include("ifelse.jl")
include("error.jl")


# include("spec_printing.jl")


# if VERSION >= v"1.12"
# 	const get_cache = OncePerProcess{Cache}() do
# 		Cache(@get_scratch!("ReproducibleJobs"))
# 	end
# else # Prior to Julia 1.12 we don't have OncePerProcess
# 	global_cache = Ref{Union{Nothing,Cache}}()
# 	get_cache() = global_cache[]
# 	function __init__()
# 		global_cache[] = Cache(@get_scratch!("ReproducibleJobs"))
# 	end
# end

# Do this to allow setting a custom cache for unit tests (even when just including "runtests.jl").
# Might be refactored later.
let cache::Union{Nothing,Cache} = nothing
	global function get_cache()::Cache
		cache = @something cache Cache(@get_scratch!("ReproducibleJobs"))
		cache
	end
	global function set_cache!(c)
		cache = c
	end
	global function with_cache(f, c)
		old_cache = cache
		try
			cache = c
			f()
		finally
			cache = old_cache
		end
	end
end


end
