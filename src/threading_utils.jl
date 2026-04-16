function periodic_wait(f, done::Threads.Atomic{Bool}, event::Base.Event, timeout=0.05)
	@async begin
		while !done[]
			sleep(timeout)
			notify(event)
		end
	end

	while !done[]
		wait(event)
		f()
	end
end
