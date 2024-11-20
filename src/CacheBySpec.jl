module CacheBySpec

using StableHashTraits
using ReadOnlyArrays
using Scratch: @get_scratch!
using JLD2: jldsave, load
import AbstractTrees # for pretty printing
using CodecZlib
using SHA

export
	Deduplicator,
	deduplicate!,
	Spec,
	Job,
	print_spec,
	fetch!,
	forward!,
	forward_once!,
	fetched

include("read_only.jl")
include("nested.jl")
include("deduplicator.jl")
include("versioned_function.jl")
include("preprocessor.jl")
include("spec.jl")
include("spec_meta.jl")
include("barrier.jl")
include("prefetch.jl")
include("spec_printing.jl")
include("cache.jl")
include("job.jl")
include("scheduler.jl")

include("paths.jl")

include("ifelse.jl")

end
