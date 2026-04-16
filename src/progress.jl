function move_cursor_up(io, n; clear=true)
	if clear
		print(io, "\e[A\e[2K" ^ n)
	else
		print(io, "\r\u1b[A" ^ n) # less flickering - but requires us to print over all chars (i.e. fill with " " until prev length of a line)
	end
end
move_cursor_up(n; kwargs...) = move_cursor_up(stdout, n; kwargs...)



abstract type AbstractProgressItem end


struct DisplayItem
	text::Union{String,AnnotatedString}
	time::Float64
	done::Bool
end


mutable struct ProgressItem <: AbstractProgressItem
	lock::ReentrantLock
	text::Union{String,AnnotatedString}
	start_time::Float64
	finish_time::Float64
end
function ProgressItem(text; finished=false, show_time=true)
	t = time()
	start_time = show_time ? t : 0.0

	if finished
		ProgressItem(ReentrantLock(), text, start_time, t)
	else
		ProgressItem(ReentrantLock(), text, start_time, Inf)
	end
end
ProgressItem(; kwargs...) = ProgressItem(""; kwargs...)

function set_text!(item::ProgressItem, text::Union{Nothing,String,AnnotatedString}=nothing; finished=false)
	lock(item.lock) do
		if finished
			t = time()
			item.finish_time = t
		end
		text !== nothing && (item.text = text)
		nothing
	end
end
function get_display_item(item::ProgressItem, t::Float64)
	lock(item.lock) do
		run_time = iszero(item.start_time) ? 0.0 : min(t,item.finish_time)-item.start_time
		done = item.finish_time != Inf
		DisplayItem(item.text, run_time, done)
	end
end



mutable struct ListNode{T}
	item::T
	next::Union{Nothing,ListNode{T}}
end
ListNode(item) = ListNode(item, nothing)



mutable struct ProgressDisplay
	lock::ReentrantLock
	nlines::Int # the number of active lines
	head::ListNode{ProgressItem}
	tail::ListNode{ProgressItem}
	display_items::Vector{DisplayItem}
	removed_items::Vector{DisplayItem}
end
function ProgressDisplay()
	head = ListNode(ProgressItem())
	ProgressDisplay(ReentrantLock(), 0, head, head, [], [])
end

function Base.empty!(pd::ProgressDisplay)
	lock(pd.lock) do
		pd.nlines = 0
		pd.head = pd.tail = ListNode(ProgressItem())
		empty!(pd.display_items)
	end
end

function add_item!(pd::ProgressDisplay, item::ProgressItem)
	lock(pd.lock) do
		li = ListNode(item)
		pd.tail.next = li
		pd.tail = li
		item
	end
end


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


function print_display(io, pd::ProgressDisplay)
	empty!(pd.display_items)
	empty!(pd.removed_items)

	n = pd.nlines
	t = lock(pd.lock) do
		t = time()
		prev = pd.head
		curr = prev.next
		while curr !== nothing
			di = get_display_item(curr.item, t)
			
			if di.done
				isempty(di.text) || push!(pd.removed_items, di)
				prev.next = curr.next
				curr === pd.tail && (pd.tail = prev)
			else
				isempty(di.text) || push!(pd.display_items, di)
				prev = curr
			end
			curr = curr.next
		end
		pd.nlines = length(pd.display_items)

	end

	move_cursor_up(io, n)

	for di in Iterators.flatten((Iterators.reverse(pd.removed_items), Iterators.reverse(pd.display_items)))
		print(io, di.text, " ")
		print_duration(io, di.time)
		di.done && print(io, styled"{bright_black:Done.}")
		println(io)
	end

end
print_display(pd::ProgressDisplay) = print_display(stdout, pd)
