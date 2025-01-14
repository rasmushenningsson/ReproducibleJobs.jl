module CacheBySpec

using StableHashTraits
using ReadOnlyArrays
using Scratch: @get_scratch!
using JLD2: jldsave, load
import AbstractTrees # for pretty printing
using CodecZstd: ZstdFrameCompressor
using SHA
import Dates # for printing of timestamped paths

using DataFrames # TODO: Use package extension?
using SparseArrays # TODO: Use package extension?

export
	Deduplicator,
	Spec,
	Job,
	TimestampedFilePath,
	unmanage,
	deduplicate!,
	print_spec,
	fetch!,
	forward!,
	forward,
	forward_once!,
	forward_once,
	prefetch,
	ifelse_job,
	checksummedfilepath_job

# Use public keyword in Julia versions where it is available
if VERSION >= v"1.11.0-DEV.469"
    let str = """
        public unsafe_unmanage
        """
        eval(Meta.parse(str))
    end
end



include("read_only.jl")
include("managed.jl")
include("kwarg_vector.jl")
include("nested.jl")
include("deduplicator.jl")
include("versioned_function.jl")
include("arg_processing.jl")
include("spec.jl")
include("spec_meta.jl")
include("spec_printing.jl")
include("cache.jl")
include("job.jl")
include("scheduler.jl")

include("paths.jl")

include("ifelse.jl")

end
