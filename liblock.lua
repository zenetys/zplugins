-- Copyright Julien Thomas < julthomas @ free.fr >
-- Copyright Zenetys < jthomas @ zenetys.com >
-- Author: Julien Thomas
-- Licence: MIT

local fcntl = require('posix.fcntl')
local stat = require('posix.sys.stat')
local time = require('posix.time')
local unistd = require('posix.unistd')

function sleep(seconds)
    local int, frac = math.modf(seconds)
    local ts = { tv_sec = int, tv_nsec = frac * 1e9 }
    time.nanosleep(ts);
end

local Lock = {}
Lock.__index = Lock

function Lock.new(file)
    local self = setmetatable({}, Lock)
    self.file = file
    self.fd = nil
    self.lock_opts = { l_whence = fcntl.SEEK_SET, l_start = 0, l_len = 0 }
    return self
end

function Lock:lock(l_type, max_tries, sleep_sec)
    if not l_type then l_type = fcntl.F_WRLCK end
    if not max_tries or max_tries < 1 then max_tries = 1 end
    if not sleep_sec then sleep_sec = 1 end
    if not self.fd then
        local fd, err = fcntl.open(self.file, fcntl.O_CREAT + fcntl.O_RDWR +
            fcntl.O_TRUNC + fcntl.O_NONBLOCK, stat.S_IRUSR + stat.S_IWUSR +
            stat.S_IRGRP + stat.S_IROTH)
        if not fd then return fd, err end
        self.fd = fd
    end
    self.lock_opts.l_type = l_type
    local tries = 0, ret, err
    while true do
        tries = tries + 1
        ret, err = fcntl.fcntl(self.fd, fcntl.F_SETLK, self.lock_opts)
        if ret or tries >= max_tries then break end
        ret, err = pcall(function() sleep(sleep_sec) end)
        if not ret then break end
    end
    return ret, err
end

function Lock:rlock(...) return self:lock(fcntl.F_RDLCK, ...) end
function Lock:wlock(...) return self:lock(fcntl.F_WRLCK, ...) end

function Lock:unlock()
    if not self.fd then return end
    self.lock_opts.l_type = fcntl.F_UNLCK
    local ret, err = fcntl.fcntl(self.fd, fcntl.F_SETLK, self.lock_opts)
    if unistd.close(self.fd) ~= nil then self.fd = nil end
    return ret, err
end

return Lock
