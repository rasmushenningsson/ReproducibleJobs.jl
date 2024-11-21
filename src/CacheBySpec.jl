module CacheBySpec

using StableHashTraits
using ReadOnlyArrays
using Scratch: @get_scratch!
using JLD2: jldsave, load
import AbstractTrees # for pretty printing
using CodecZlib
using SHA
import Dates # for printing of timestamped paths

export
	Deduplicator,
	deduplicate!,
	Spec,
	Job,
	print_spec,
	fetch!,
	forward!,
	forward,
	forward_once!,
	forward_once,
	prefetch,
	ifelse_job,
	checksummedfilepath_job


include("read_only.jl")
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
