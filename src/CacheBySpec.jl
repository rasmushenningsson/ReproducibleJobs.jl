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
	fetch!

include("nested.jl")
include("read_only.jl")
include("deduplicator.jl")
include("versioned_function.jl")
include("spec.jl")
include("cache.jl")
include("job.jl")
include("scheduler.jl")

include("hash_by_value.jl")

end
