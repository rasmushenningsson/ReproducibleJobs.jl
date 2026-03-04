module Deduplicators

using StableHashTraits
using ReadOnlyArrays
using JLD2: JLD2, jldopen, ZstdFilter

using SparseArrays # TODO: Move to package extension
using DataFrames # TODO: Move to package extension


export
	Deduplicator,
	Cache,
	CompoundResult,
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


include("hash.jl")
include("compound_result.jl")
include("deduplicator.jl")
include("cache.jl")

end
