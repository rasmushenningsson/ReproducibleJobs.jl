module ReproducibleJobs


using StableHashTraits
using ReadOnlyArrays
import TupleTools # for sorting of tuples
using JLD2: JLD2, jldopen, ZstdFilter

using Preferences # For persisting cache dir

using DataStructures: DataStructures, MutableBinaryMinHeap # For LRU functionality
using SHA

using LinearAlgebra # For handling copy_arg(transposed)

using DataFrames # TODO: Use package extension?
using SparseArrays # TODO: Use package extension?

import AbstractTrees # for pretty printing
using StyledStrings # For Spec printing
import Dates # for printing of timestamped paths

using Statistics # just to be able to put `mean` in `SupportedFunctions`...

export
	Deduplicator,
	Cache,
	Scheduler,
	# Spec, ?
	SpecRef,
	CompoundResult,
	AbstractPreprocess,
	Preprocess,
	TimestampedFilePath,
	ChecksummedFilePath,
	deduplicate!,
	print_spec,
	fetch!,
	forward!,
	forward,
	forward_once!,
	forward_once,
	fetched,
	prefetched,
	ifelse_spec,
	error_spec,
	checksummedfilepath_spec

# Use public keyword in Julia versions where it is available
if VERSION >= v"1.11.0-DEV.469"
	let str = """
		public
			Preprocessing,
			ProgressBar, # experimental
			get_cache_path,
			persist_cache_path!,
			create_spec,
			cached
		"""
		eval(Meta.parse(str))
	end
end

# Used throughout ReproducibleJobs.jl instead of Nothing, since Nothing can be an actual value sometimes
struct NotValid end


# ReadOnlyArray accepts any AbstractArray as the underlying object - these types enforce Array to be used
const ROArray{T,N} = ReadOnlyArray{T,N,Array{T,N}}
const ROVec{T} = ROArray{T,1}
const ROMat{T} = ROArray{T,2}

const ROBitArray{N} = ReadOnlyArray{Bool,N,BitArray{N}}
const ROBitVec = ROBitArray{1}
const ROBitMat = ROBitArray{2}


persist_cache_path!(path::String) = @set_preferences!("cache_path"=>expanduser(path))
get_cache_path() = @something @load_preference("cache_path") ".cache"


# Deduplicator and cache
include("utils.jl")
include("hash.jl")
include("compound_result.jl")
include("deduplicator.jl")
include("cache.jl")


# Progress utils
include("progress.jl")


# Specs and scheduling
include("spec.jl")
include("spec_meta.jl")
include("preprocess.jl")
include("processing_exception.jl")
include("lru_cache.jl")
include("scheduler.jl")

include("paths.jl")

include("ifelse.jl")
include("error.jl")


include("spec_printing.jl")


# Do this to allow setting a custom scheduler/cache for unit tests (even when just including "runtests.jl").
# Might be refactored later.
let scheduler::Union{Nothing,Scheduler} = nothing
	global function get_scheduler()::Scheduler
		scheduler = @something scheduler Scheduler()
		scheduler
	end
	global function set_scheduler!(s)
		scheduler = s
	end
	global function with_scheduler(f, s)
		old_scheduler = scheduler
		try
			scheduler = s
			f()
		finally
			scheduler = old_scheduler
		end
	end
end


end
