module utils

export backoff

using Base.Dates

"""Backoff attempts of `task` exponentially"""
function backoff(task::Function, check::Function, max_attempts::Int64, max_backoff::TimePeriod)
    max_backoff = Millisecond(max_backoff)
    for attempt = 1:max(max_attempts, 1)
        result = task()
        if check(result)
            break
        elseif attempt < max_attempts
            delay = min(Millisecond(2 ^ attempt + floor(rand() * 1000)), max_backoff)
            Base.warn("Unable to complete request: Retrying ($attempt/$max_attempts) in $delay")
            sleep(delay / Millisecond(Second(1)))
        else
            Base.warn("Unable to complete request: Stopping ($attempt/$max_attempts)")
        end
    end
end

end
