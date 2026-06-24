module ReproducibleJobs


using StableHashTraits
using ReadOnlyArrays
import TupleTools # for sorting of tuples
using JLD2: JLD2, jldopen, ZstdFilter

using Preferences # For persisting cache dir

using DataStructures: DataStructures, MutableBinaryMinHeap # For LRU functionality
using SHA

using ScopedValues # for cancellation

using LinearAlgebra # For handling copy_arg(transposed)

using DataFrames # TODO: Use package extension?
using SparseArrays # TODO: Use package extension?

import AbstractTrees # for pretty printing
using StyledStrings: AnnotatedString, @styled_str # For Spec printing
import Dates # for printing of timestamped paths

export
	Scheduler,
	Spec,
	SpecRef,
	Job,
	TimestampedFilePath,
	ChecksummedFilePath,
	ProgressDisplay, # Experimental
	WatchableLog, # Experimental
	print_spec,
	fetch!,
	forward!,
	forward_once!,
	fetched,
	prefetched,
	is_cancelled,
	throw_if_cancelled,
	get_failed_job,
	get_failed_spec,
	set_progress_display!, # Experimental
	ifelse_job,
	error_job,
	checksummedfilepath_job

# Use public keyword in Julia versions where it is available
if VERSION >= v"1.11.0-DEV.469"
	let str = """
		public
			Deduplicator,
			Cache,
			CompoundResult,
			AbstractPreprocess,
			Preprocess,
			Preprocessing,
			ProgressBar, # experimental
			deduplicate!,
			get_cache_path,
			persist_cache_path!,
			create_job,
			cached,
			get_scheduler,
			set_scheduler!,
			with_scheduler,
			register_function!
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


"""
    persist_cache_path!(path::String)

Persist the path to the on-disk cache directory in LocalPreferences.toml, using Preferences.jl.
This path is used by [`Scheduler`](@ref) to store cached computation results.

See also [`get_cache_path`](@ref).
"""
persist_cache_path!(path::String) = @set_preferences!("cache_path"=>expanduser(path))

"""
    get_cache_path() -> String

Return the path to the on-disk cache directory, defaulting to `".cache"` if not previously set via
[`persist_cache_path!`](@ref).

See also [`persist_cache_path!`](@ref).
"""
get_cache_path() = @something @load_preference("cache_path") ".cache"


# Deduplicator and cache
include("utils.jl")
include("hash.jl")
include("compound_result.jl")
include("deduplicator.jl")
include("cache.jl")


# Progress utils
include("watchable_log.jl")
include("progress.jl")


# Specs and scheduling
include("spec.jl")
include("spec_meta.jl")
include("preprocess.jl")
include("processing_exception.jl")
include("lru_cache.jl")
include("scheduler.jl")
include("scheduler_old.jl") # will be removed

include("paths.jl")

include("ifelse.jl")
include("error.jl")


include("spec_printing.jl")


"""
    get_scheduler() -> Scheduler

Return the global [`Scheduler`](@ref), creating a default one if none has been set.

See also [`set_scheduler!`](@ref), [`with_scheduler`](@ref).
"""
function get_scheduler end

"""
    set_scheduler!(scheduler)

Set the global [`Scheduler`](@ref).

See also [`get_scheduler`](@ref), [`with_scheduler`](@ref).
"""
function set_scheduler! end

"""
    with_scheduler(f, scheduler)

Execute `f()` with `scheduler` as the global [`Scheduler`](@ref), restoring the previous
scheduler afterwards. This is the recommended way to use a custom scheduler for a block of code.
Mostly useful for unit testing.

# Examples
```julia
with_scheduler(Scheduler(; dir=mktempdir())) do
    job = create_job(my_function, data; __version=v"0.1.0")
    fetch!(job)
end
```

See also [`Scheduler`](@ref), [`get_scheduler`](@ref), [`set_scheduler!`](@ref).
"""
function with_scheduler end

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


include("precompile.jl")

end
