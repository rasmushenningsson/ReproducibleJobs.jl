"""
    WatchableLog(filename, nlines)

A file-backed log that overwrites itself from the top on every tick, keeping at most `nlines`
visible. Useful for redirecting [`ProgressDisplay`](@ref) output when stdout is not a TTY.
The file ends with `--- Done ---` when a call to [`fetch!`](@ref)/[`forward!`](@ref) completes.

Watch it live with `watch -n 0.1 --color "cat filename"` or just `cat filename` on demand.

!!! note "Experimental"
    This API is experimental and may change.

# Examples
```julia
set_progress_display!(ProgressDisplay(; io=WatchableLog("progress.log", 8)))
```

See also [`ProgressDisplay`](@ref), [`set_progress_display!`](@ref).
"""
mutable struct WatchableLog
    file::IO
    nlines::Int            # max lines visible in the file at once
    lines::Vector{String}  # line buffer: history above, active below
    cursor::Int            # next write position (1-indexed)
    scratch::IOBuffer      # accumulates mid-line emit() calls
    scratch_ctx::IOContext # wraps scratch with :color=>true for styled strings
end

function WatchableLog(filename::AbstractString, nlines::Int)
    scratch = IOBuffer()
    WatchableLog(open(filename, "w+"), nlines, String[], 1, scratch, IOContext(scratch, :color => true))
end

emit(wl::WatchableLog, args...) = print(wl.scratch_ctx, args...)

function emit_clear(wl::WatchableLog, args...)
    emit(wl, args..., "\n")
    line = String(take!(wl.scratch))
    if wl.cursor <= length(wl.lines)
        wl.lines[wl.cursor] = line
    else
        push!(wl.lines, line)
        if length(wl.lines) > wl.nlines
            popfirst!(wl.lines)
            wl.cursor -= 1  # compensate for the shift
        end
    end
    wl.cursor += 1
end

function _end_tick!(wl::WatchableLog, nlines, final)
    wl.cursor -= nlines  # reposition to top of active area for next tick
    seek(wl.file, 0)
    for line in wl.lines
        print(wl.file, line)
    end
    final && print(wl.file, "--- Done ---\n")
    truncate(wl.file, position(wl.file))
    flush(wl.file)
end
