function move_cursor_up(io, n)
	# print(io, "\e[A\e[2K" ^ n) # This version also clears when moving up
	print(io, "\r\u1b[A" ^ n) # This only moves up
end

println_clear(io) = println(io, "\e[K") # clear the rest of the line


abstract type AbstractProgressItem end



mutable struct ProgressText <: AbstractProgressItem
	type::Symbol # One of :text, :timed, :pending
	text::Union{String,AnnotatedString}
	const start_time::Float64
	finished::Bool
	function ProgressText(type, text, start_time, finished)
		@assert type in (:text, :timed, :pending)
		new(type, text, start_time, finished)
	end
end
ProgressText(text; type=:timed) = ProgressText(type, text, time(), false)
ProgressText(; kwargs...) = ProgressText(""; kwargs...)



mutable struct ProgressBarItem <: AbstractProgressItem
	text::Union{String,AnnotatedString}
	const n_chars::Int
	const n::Int # Total number of steps
	@atomic i::Int # Current pos in 0:n
	const start_time::Float64
	finished::Bool
end
ProgressBarItem(text, n; n_chars=40) = ProgressBarItem(text, n_chars, n, 0, time(), false)

next!(item::ProgressBarItem) = @atomic item.i += 1



const ProgressItemUnion = Union{ProgressText, ProgressBarItem}



mutable struct ListNode{T}
	const item::T
	next::Union{Nothing,ListNode{T}}
end
ListNode(::Type{T}, item) where T = ListNode{T}(item, nothing)
ListNode(item) = ListNode(item, nothing)



struct ProgressMessageAddItem
	item::ProgressItemUnion
	# TODO: optional parent for nesting
end

struct ProgressMessageSetText
	item::ProgressItemUnion
	text::Union{String,AnnotatedString}
end

struct ProgressMessageRemoveItem
	item::ProgressItemUnion
	t::Float64 # Time at message creation
	text::Union{String,AnnotatedString}
end

struct ProgressMessageInfo
	text::Union{String,AnnotatedString}
end


const ProgressMessageUnion = Union{ProgressMessageAddItem, ProgressMessageSetText, ProgressMessageRemoveItem, ProgressMessageInfo}

mutable struct ProgressDisplay
	nlines::Int # the number of active lines
	head::ListNode{ProgressItemUnion} # dummy item, we always ignore the first item in the list
	tail::ListNode{ProgressItemUnion}
	channel::Channel{ProgressMessageUnion}
	start_time::Float64
	last_print_time::Float64
	min_display_time::Float64 # suppress all output (except info messages at final) if elapsed < this
	print_interval::Float64   # minimum time between redraws of the active display
end
function ProgressDisplay(; min_display_time=0.1, print_interval=0.05)
	head = ListNode(ProgressItemUnion, ProgressText())
	ProgressDisplay(0, head, head, Channel{ProgressMessageUnion}(Inf), time(), -Inf, min_display_time, print_interval)
end

function Base.empty!(pd::ProgressDisplay)
	pd.nlines = 0
	pd.head = pd.tail = ListNode(ProgressItemUnion, ProgressText())
	empty!(pd.channel)
	pd.start_time = time()
	pd.last_print_time = -Inf
	pd
end

# Inserts at the front - because this gives the correct print order.
function _add_item!(pd::ProgressDisplay, item::ProgressItemUnion)
	li = ListNode(ProgressItemUnion, item)
	# head is a dummy item, so we insert just after it
	li.next = pd.head.next
	pd.head.next = li
	pd.tail === pd.head && (pd.tail = li)
	item
end
add_item!(pd::ProgressDisplay, item::ProgressItemUnion) = (put!(pd.channel, ProgressMessageAddItem(item)); item)

_set_text!(item::ProgressItemUnion, text::Union{String,AnnotatedString}) = item.text = text
set_text!(pd::ProgressDisplay, item::ProgressItemUnion, text::Union{String,AnnotatedString}) = (put!(pd.channel, ProgressMessageSetText(item, text)); nothing)

_set_finished!(item::ProgressItemUnion) = item.finished = true
remove_item!(pd::ProgressDisplay, item::ProgressItemUnion, text=styled"{bright_black:Done}") =
	(put!(pd.channel, ProgressMessageRemoveItem(item, time(), text)); nothing)

add_info_item!(pd::ProgressDisplay, text::Union{String,AnnotatedString}) = (put!(pd.channel, ProgressMessageInfo(text)); nothing)



# TODO: share code with duration_string(s::Real)
function print_duration(io, s::Real; min_s=0.05)
	if s > 60
		s = round(Int, s)
		m,s = divrem(s, 60)
		h,m = divrem(m, 60)
		h>0 && print(io, h, "h ")
		print(io, m, "m ", s, "s ")
	elseif s >= min_s
		print(io, round(s;digits=1), "s ")
	end
end


# returns true if something was printed
function print_item(io, item::ProgressText, t; finish_time=nothing, finish_text=nothing)
	run_time = @something(finish_time, t) - item.start_time
	if item.type === :pending
		if run_time < 0.05
			return false
		else
			item.type = :timed
		end
	end

	isempty(item.text) || print(io, item.text, " ")

	item.type === :timed && print_duration(io, run_time)
	finish_text !== nothing && print(io, finish_text)
	println_clear(io)
	return true
end


function print_item(io, item::ProgressBarItem, t; finish_time=nothing, finish_text=nothing)
	run_time = @something(finish_time, t) - item.start_time

	# run_time < 0.05 && return false # TODO: Enable - only display if some time did pass

	isempty(item.text) || print(io, item.text, " ")

	i = @atomic item.i
	i = clamp(i, 0, item.n)

	f = i / item.n # fraction completed
	p = round(Int, f*100) # percentage completed

	k = round(Int, item.n_chars*f) # number of chars to fill

	# # TODO: Use fewer temporary objects for this?
	print(io, lpad(p,3), "%: ", "─"^k, " "^(item.n_chars-k+1))

	if i == 0
		print(io, " ETA: ?")
	elseif i < item.n
		spent = t-item.start_time
		eta = spent*(1-f)/f
		# str * " ETA: " * duration_string(eta)
		print(io, "ETA: ")
		print_duration(io, eta; min_s = 0.0)
	end

	if finish_text !== nothing
		print_duration(io, run_time)
		print(io, finish_text)
	end

	println_clear(io)
	return true
end



function print_display(io, pd::ProgressDisplay; final=false)
	t = time()
	suppress_output = t - pd.start_time < pd.min_display_time

	# Don't touch the channel until we're final or past the threshold.
	# This keeps messages queued so info messages are never silently dropped.
	if !final
		suppress_output && return
		t - pd.last_print_time < pd.print_interval && return # rate-limit redraws
	end

	# Process item updates (isempty!+take! works since we only have one consumer task)
	# Removed items and info messages print here and stay permanently above the active display.
	# Removed items are only printed if beyond threshold; info messages are always printed.
	while !isempty(pd.channel)
		msg = take!(pd.channel)
		if msg isa ProgressMessageAddItem
			_add_item!(pd, msg.item)
		elseif msg isa ProgressMessageSetText
			_set_text!(msg.item, msg.text)
		elseif msg isa ProgressMessageRemoveItem
			_set_finished!(msg.item) # mark for removal
			suppress_output || print_item(io, msg.item, t; finish_time=msg.t, finish_text=msg.text) # print removed items first (in order of removal)
		else#if msg isa ProgressMessageInfo
			msg::ProgressMessageInfo # a one-off message
			print(io, msg.text)
			println_clear(io)
		end
	end

	suppress_output && return # skip active items for fast calls

	pd.last_print_time = t

	# Print remaining items and get rid of removed ones
	nlines = 0
	prev = pd.head
	curr = prev.next
	while curr !== nothing
		if curr.item.finished
			# Remove item
			prev.next = curr.next
			curr === pd.tail && (pd.tail = prev)
		else
			nlines += print_item(io, curr.item, t)
			prev = curr
		end
		curr = curr.next
	end
	pd.nlines = nlines

	# Move cursor back to the top of the active display so the next call
	# overwrites it in place. Skipped on the final call so the cursor stays
	# below the display and subsequent output appears underneath.
	final || move_cursor_up(io, nlines)
end
print_display(pd::ProgressDisplay; kwargs...) = print_display(stdout, pd; kwargs...)



struct ProgressBar
	pd::ProgressDisplay
	text::Union{String,AnnotatedString}
	n_chars::Int
	item::Base.RefValue{Union{Nothing, ProgressBarItem}}
end
ProgressBar(pd, text; n_chars=40) = ProgressBar(pd, text, n_chars, Ref{Union{Nothing, ProgressBarItem}}(nothing))
ProgressBar(text; kwargs...) = ProgressBar(get_scheduler().progress_display, text; kwargs...)


# start
function (pb::ProgressBar)(n::Int)
	@assert pb.item[] === nothing
	pb.item[] = add_item!(pb.pd, ProgressBarItem(pb.text, n))
	nothing
end

# take one step
function (pb::ProgressBar)()
	item = pb.item[]
	@assert item !== nothing
	i = next!(item)
	i == item.n && remove_item!(pb.pd, item)
end

# This is needed to enable compatibility with ProgressMeter, but we do removal automatically when taking the last step
(pb::ProgressBar)(::Val{:done}) = nothing
