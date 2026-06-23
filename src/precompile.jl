using PrecompileTools

_pc_preproc(::Preprocessing, x) = create_job(identity, x; __version=v"1.0.0")
_pc_preproc_fetched(::Preprocessing, x) = create_job(identity, fetched(x); __version=v"1.0.0")
_pc_compound(x; __version=v"1.0.0") = CompoundResult(; a=x, b=x+1)

@compile_workload begin
	redirect_stdout(devnull) do # Avoid noise from precompilation
		mktempdir() do dir
			with_scheduler(Scheduler(; dir)) do
				# Basic fetch
				j = create_job(identity, 1; __version=v"1.0.0")
				fetch!(j)

				# Preprocessing
				pj = create_job(Preprocess(_pc_preproc), j)
				fetch!(pj)

				# fetched dep: computed eagerly during preprocessing
				pj_f = create_job(Preprocess(_pc_preproc_fetched), j)
				fetch!(pj_f)

				# prefetched: dep collapsed to value before parent runs
				j2 = create_job(identity, 2; __version=v"1.0.0")
				pf = create_job(identity, prefetched(j2); __version=v"1.0.0")
				fetch!(pf)

				# On-disk caching
				cj = cached(create_job(identity, 3; __version=v"1.0.0"))
				fetch!(cj)

				# CompoundResult with sub-result loading
				inner = create_job(_pc_compound, 4; __version=v"1.0.0")
				fetch!(cached(inner, "a"))

				# checksummedfilepath_job
				fp = joinpath(dir, "pc_file.txt")
				write(fp, "hello")
				cfp = checksummedfilepath_job(fp)
				fetch!(cfp)
			end
		end
	end
end
