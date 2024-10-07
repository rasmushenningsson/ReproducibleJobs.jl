module CacheBySpec

using StableHashTraits
import AbstractTrees # for pretty printing

export
	Deduplicator,
	deduplicate!,
	Spec

include("read_only.jl")
include("deduplicator.jl")
include("versioned_function.jl")
include("spec.jl")

end
