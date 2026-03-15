module ReproducibleJobs

using StableHashTraits
using ReadOnlyArrays
using JLD2: JLD2, jldopen, load, ZstdFilter
import AbstractTrees # for pretty printing
using SHA
import Dates # for printing of timestamped paths

using LinearAlgebra # For handling copy_arg(transposed)

using DataFrames # TODO: Use package extension?
using SparseArrays # TODO: Use package extension?

using StyledStrings # For Spec printing

export
	Deduplicator,
	Cache,
	Scheduler,
	Spec,
	Job,
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
	ifelse_job,
	error_job,
	checksummedfilepath_spec

# Use public keyword in Julia versions where it is available
if VERSION >= v"1.11.0-DEV.469"
	let str = """
		public
			Preprocessing,
			get_cache_path,
			persist_cache_path!,
			create_spec,
			cached
		"""
		eval(Meta.parse(str))
	end
end

include("Deduplicators/Deduplicators.jl")
using .Deduplicators
using .Deduplicators: ROArray, ROVec, ROMat, ROBitVec



include("spec.jl")
include("spec_meta.jl")
include("preprocess.jl")
include("job.jl")
include("processing_exception.jl")
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
