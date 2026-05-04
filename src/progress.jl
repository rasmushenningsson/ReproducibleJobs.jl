function move_cursor_up(io, n; clear=true)
	if clear
		print(io, "\e[A\e[2K" ^ n)
	else
		print(io, "\r\u1b[A" ^ n) # less flickering - but requires us to print over all chars (i.e. fill with " " until prev length of a line)
	end
end
move_cursor_up(n; kwargs...) = move_cursor_up(stdout, n; kwargs...)



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
end
function ProgressDisplay()
	head = ListNode(ProgressItemUnion, ProgressText())
	ProgressDisplay(0, head, head, Channel{ProgressMessageUnion}(Inf))
end

function Base.empty!(pd::ProgressDisplay)
	pd.nlines = 0
	pd.head = pd.tail = ListNode(ProgressItemUnion, ProgressText())
	empty!(pd.channel)
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
	println(io)
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

	println(io)
	return true
end



function print_display(io, pd::ProgressDisplay)
	move_cursor_up(io, pd.nlines)

	t = time()

	# Process item updates (isempty!+take! works since we only have one consumer task)
	while !isempty(pd.channel)
		msg = take!(pd.channel)
		if msg isa ProgressMessageAddItem
			_add_item!(pd, msg.item)
		elseif msg isa ProgressMessageSetText
			_set_text!(msg.item, msg.text)
		elseif msg isa ProgressMessageRemoveItem
			_set_finished!(msg.item) # mark for removal
			print_item(io, msg.item, t; finish_time=msg.t, finish_text=msg.text) # print removed items first (in order of removal)
		else#if msg isa ProgressMessageInfo
			msg::ProgressMessageInfo
			println(io, msg.text) # one-off
		end
	end

	# Print remaining items
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
end
print_display(pd::ProgressDisplay) = print_display(stdout, pd)



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
