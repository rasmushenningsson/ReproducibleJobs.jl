module Deduplicators

using StableHashTraits
using ReadOnlyArrays
using JLD2: JLD2, jldopen, ZstdFilter

using SparseArrays # TODO: Move to package extension
using DataFrames # TODO: Move to package extension

using Preferences


export
	Deduplicator,
	Cache,
	CompoundResult,
	persist_cache_path!,
	get_cache_path,
	deduplicate!,
	cache_get!,
	cache_get_subresult!



# ReadOnlyArray accepts any AbstractArray as the underlying object - these types enforce Array to be used
const ROArray{T,N} = ReadOnlyArray{T,N,Array{T,N}}
const ROVec{T} = ROArray{T,1}
const ROMat{T} = ROArray{T,2}

const ROBitArray{N} = ReadOnlyArray{Bool,N,BitArray{N}}
const ROBitVec = ROBitArray{1}
const ROBitMat = ROBitArray{2}


persist_cache_path!(path::String) = @set_preferences!("cache_path"=>expanduser(path))
get_cache_path() = @something @load_preference("cache_path") ".cache"


include("hash.jl")
include("compound_result.jl")
include("deduplicator.jl")
include("cache.jl")

end
