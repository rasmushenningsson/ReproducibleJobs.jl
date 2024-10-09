module CacheBySpec

using StableHashTraits
import AbstractTrees # for pretty printing

export
	Deduplicator,
	deduplicate!,
	Spec,
	Job,
	fetch!

include("read_only.jl")
include("deduplicator.jl")
include("versioned_function.jl")
include("spec.jl")
include("job.jl")

end
