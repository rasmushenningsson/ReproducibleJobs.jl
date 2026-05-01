function move_cursor_up(io, n; clear=true)
	if clear
		print(io, "\e[A\e[2K" ^ n)
	else
		print(io, "\r\u1b[A" ^ n) # less flickering - but requires us to print over all chars (i.e. fill with " " until prev length of a line)
	end
end
move_cursor_up(n; kwargs...) = move_cursor_up(stdout, n; kwargs...)



abstract type AbstractProgressItem end



mutable struct ProgressItem <: AbstractProgressItem
	type::Symbol # One of :text, :timed, :pending
	text::Union{String,AnnotatedString}
	start_time::Float64
	finished::Bool
	function ProgressItem(type, text, start_time, finished)
		@assert type in (:text, :timed, :pending)
		new(type, text, start_time, finished)
	end
end
ProgressItem(text; type=:timed) = ProgressItem(type, text, time(), false)
ProgressItem(; kwargs...) = ProgressItem(""; kwargs...)




mutable struct ListNode{T}
	const item::T
	next::Union{Nothing,ListNode{T}}
end
ListNode(item) = ListNode(item, nothing)



struct ProgressMessageAddItem
	item::ProgressItem
	# TODO: optional parent for nesting
end

struct ProgressMessageSetText
	item::ProgressItem
	text::Union{String,AnnotatedString}
end

struct ProgressMessageRemoveItem
	item::ProgressItem
	t::Float64 # Time at message creation
	text::Union{String,AnnotatedString}
end

struct ProgressMessageInfo
	text::Union{String,AnnotatedString}
end


const ProgressMessageUnion = Union{ProgressMessageAddItem, ProgressMessageSetText, ProgressMessageRemoveItem, ProgressMessageInfo}

mutable struct ProgressDisplay
	nlines::Int # the number of active lines
	head::ListNode{ProgressItem} # dummy item, we always ignore the first item in the list
	tail::ListNode{ProgressItem}
	channel::Channel{ProgressMessageUnion}
end
function ProgressDisplay()
	head = ListNode(ProgressItem())
	ProgressDisplay(0, head, head, Channel{ProgressMessageUnion}(Inf))
end

function Base.empty!(pd::ProgressDisplay)
	pd.nlines = 0
	pd.head = pd.tail = ListNode(ProgressItem())
	empty!(pd.channel)
end

# Inserts at the front - because this gives the correct print order.
function _add_item!(pd::ProgressDisplay, item::ProgressItem)
	li = ListNode(item)
	# head is a dummy item, so we insert just after it
	li.next = pd.head.next
	pd.head.next = li
	pd.tail === pd.head && (pd.tail = li)
	item
end
add_item!(pd::ProgressDisplay, item::ProgressItem) = (put!(pd.channel, ProgressMessageAddItem(item)); item)

_set_text!(item::ProgressItem, text::Union{String,AnnotatedString}) = item.text = text
set_text!(pd::ProgressDisplay, item::ProgressItem, text::Union{String,AnnotatedString}) = (put!(pd.channel, ProgressMessageSetText(item, text)); nothing)

_set_finished!(item::ProgressItem) = item.finished = true
remove_item!(pd::ProgressDisplay, item::ProgressItem, text=styled"{bright_black:Done}") =
	(put!(pd.channel, ProgressMessageRemoveItem(item, time(), text)); nothing)

add_info_item!(pd::ProgressDisplay, text::Union{String,AnnotatedString}) = (put!(pd.channel, ProgressMessageInfo(text)); nothing)



function print_duration(io, s::Real)
	if s > 60
		s = round(Int, s)
		m,s = divrem(s, 60)
		h,m = divrem(m, 60)
		h>0 && print(io, h, "h ")
		print(io, m, "m ", s, "s ")
	elseif s > 0.05
		print(io, round(s;digits=1), "s ")
	end
end


# returns true if something was printed
function print_item(io, item::ProgressItem, t; finish_time=nothing, finish_text=nothing)
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
