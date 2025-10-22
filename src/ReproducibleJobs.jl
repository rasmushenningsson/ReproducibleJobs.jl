module ReproducibleJobs

using StableHashTraits
using ReadOnlyArrays
using Scratch: @get_scratch!
using JLD2: JLD2, jldopen, load
import AbstractTrees # for pretty printing
using CodecZstd: ZstdFrameCompressor
using SHA
import Dates # for printing of timestamped paths

using LinearAlgebra # For handling copy_arg(transposed)

using DataFrames # TODO: Use package extension?
using SparseArrays # TODO: Use package extension?

export
	Deduplicator,
	Spec,
	Job,
	CompoundResult,
	AbstractPreprocess,
	Preprocess,
	TimestampedFilePath,
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
	checksummedfilepath_job

# Use public keyword in Julia versions where it is available
if VERSION >= v"1.11.0-DEV.469"
	let str = """
		public
			unsafe_unmanage,
			create_spec,
			cached
		"""
		eval(Meta.parse(str))
	end
end


include("read_only.jl")
include("managed.jl")
include("kwarg_vector.jl")
include("nested.jl")
include("hash.jl")
include("deduplicator.jl")
include("arg_processing.jl")
include("spec.jl")
include("spec_meta.jl")
include("preprocess.jl")
include("spec_printing.jl")
include("compound_result.jl")
include("cache.jl")
include("job.jl")
include("processing_exception.jl")
include("scheduler.jl")

include("paths.jl")

include("ifelse.jl")



if VERSION >= v"1.12"
	const get_cache = OncePerProcess{Cache}() do
		Cache(@get_scratch!("ReproducibleJobs"))
	end
else # Prior to Julia 1.12 we don't have OncePerProcess
	global_cache = Ref{Union{Nothing,Cache}}()
	get_cache() = global_cache[]
	function __init__()
		global_cache[] = Cache(@get_scratch!("ReproducibleJobs"))
	end
end


end
