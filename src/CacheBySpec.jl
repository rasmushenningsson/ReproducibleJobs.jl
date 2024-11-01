module CacheBySpec

using StableHashTraits
using Scratch: @get_scratch!
using JLD2: jldsave, load
import AbstractTrees # for pretty printing

export
	Deduplicator,
	deduplicate!,
	Spec,
	Job,
	print_spec,
	fetch!

include("nested.jl")
include("read_only.jl")
include("deduplicator.jl")
include("versioned_function.jl")
include("spec.jl")
include("barrier.jl")
include("spec_printing.jl")
include("cache.jl")
include("job.jl")
include("scheduler.jl")

include("hash_by_value.jl")
include("ifelse.jl")

end
