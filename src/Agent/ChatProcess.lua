-- PoB Agent Edition: a background process with pipes, for the AI chat (Stage 10).
-- Windows only (LuaJIT FFI): CreateProcess without a console window, stdout and
-- stderr read without blocking once per frame, and a job object so Cancel (or
-- closing PoB) ends the process and everything it started (the CLI, the MCP server).
-- io.popen is not used: it flashes a console window and blocks the UI thread.

local ok, ffi = pcall(require, "ffi")
if not ok or ffi.os ~= "Windows" then
	return { available = function() return false end }
end

local function def(s) pcall(ffi.cdef, s) end
def[[
typedef struct { unsigned long nLength; void* lpSecurityDescriptor; int bInheritHandle; } PobChatSA;
typedef struct {
	unsigned long cb; void* lpReserved; void* lpDesktop; void* lpTitle;
	unsigned long dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
	unsigned short wShowWindow, cbReserved2; void* lpReserved2;
	void* hStdInput; void* hStdOutput; void* hStdError;
} PobChatSI;
typedef struct { void* hProcess; void* hThread; unsigned long dwProcessId, dwThreadId; } PobChatPI;
typedef struct {
	int64_t PerProcessUserTimeLimit; int64_t PerJobUserTimeLimit; unsigned long LimitFlags;
	size_t MinimumWorkingSetSize; size_t MaximumWorkingSetSize; unsigned long ActiveProcessLimit;
	uintptr_t Affinity; unsigned long PriorityClass; unsigned long SchedulingClass;
} PobChatJobBasic;
typedef struct {
	PobChatJobBasic BasicLimitInformation;
	uint64_t ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
	size_t ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
} PobChatJobExt;
]]
for _, s in ipairs({
	"int CreatePipe(void** r, void** w, PobChatSA* sa, unsigned long size);",
	"int SetHandleInformation(void* h, unsigned long mask, unsigned long flags);",
	"int CreateProcessW(const wchar_t* app, wchar_t* cmd, void* pa, void* ta, int inherit, unsigned long flags, void* env, const wchar_t* cwd, PobChatSI* si, PobChatPI* pi);",
	"int PeekNamedPipe(void* h, void* buf, unsigned long size, unsigned long* read, unsigned long* avail, unsigned long* left);",
	"int ReadFile(void* h, void* buf, unsigned long size, unsigned long* read, void* ov);",
	"int WriteFile(void* h, const void* buf, unsigned long size, unsigned long* written, void* ov);",
	"int CloseHandle(void* h);",
	"unsigned long WaitForSingleObject(void* h, unsigned long ms);",
	"int GetExitCodeProcess(void* h, unsigned long* code);",
	"void* CreateJobObjectW(void* sa, const wchar_t* name);",
	"int SetInformationJobObject(void* job, int cls, void* info, unsigned long size);",
	"int AssignProcessToJobObject(void* job, void* proc);",
	"int TerminateJobObject(void* job, unsigned int code);",
	"unsigned long ResumeThread(void* h);",
	"int MultiByteToWideChar(unsigned int cp, unsigned long flags, const char* s, int n, wchar_t* out, int outn);",
	"unsigned long GetLastError(void);",
}) do def(s) end

local C = ffi.C
local HANDLE_FLAG_INHERIT = 1
local STARTF_USESTDHANDLES = 0x100
local CREATE_SUSPENDED, CREATE_NO_WINDOW = 0x4, 0x08000000
local KILL_ON_JOB_CLOSE, JobObjectExtendedLimitInformation = 0x2000, 9

local function wide(s)
	local n = C.MultiByteToWideChar(65001, 0, s, #s, nil, 0)
	local buf = ffi.new("wchar_t[?]", n + 1)
	C.MultiByteToWideChar(65001, 0, s, #s, buf, n)
	buf[n] = 0
	return buf
end

local Proc = { }
Proc.__index = Proc

local M = { }
function M.available() return true end

-- Quote one argument for CommandLineToArgvW rules.
function M.quote(arg)
	arg = tostring(arg)
	if arg ~= "" and not arg:find('[%s"]') then return arg end
	arg = arg:gsub('(\\*)"', function(bs) return bs .. bs .. '\\"' end):gsub('(\\+)$', '%1%1')
	return '"' .. arg .. '"'
end

-- Start cmdLine (already quoted) in cwd. Returns a process object or nil, error.
function M.start(cmdLine, cwd)
	local sa = ffi.new("PobChatSA")
	sa.nLength = ffi.sizeof("PobChatSA")
	sa.bInheritHandle = 1
	local outR, outW = ffi.new("void*[1]"), ffi.new("void*[1]")
	local inR, inW = ffi.new("void*[1]"), ffi.new("void*[1]")
	if C.CreatePipe(outR, outW, sa, 1048576) == 0 then return nil, "CreatePipe failed" end
	if C.CreatePipe(inR, inW, sa, 1048576) == 0 then C.CloseHandle(outR[0]) C.CloseHandle(outW[0]) return nil, "CreatePipe failed" end
	-- Our ends must not be inherited, or the child keeps its own stdin open forever.
	C.SetHandleInformation(outR[0], HANDLE_FLAG_INHERIT, 0)
	C.SetHandleInformation(inW[0], HANDLE_FLAG_INHERIT, 0)
	local si = ffi.new("PobChatSI")
	si.cb = ffi.sizeof("PobChatSI")
	si.dwFlags = STARTF_USESTDHANDLES
	si.hStdInput, si.hStdOutput, si.hStdError = inR[0], outW[0], outW[0]
	local pi = ffi.new("PobChatPI")
	local okCreate = C.CreateProcessW(nil, wide(cmdLine), nil, nil, 1, CREATE_SUSPENDED + CREATE_NO_WINDOW, nil, cwd and wide(cwd) or nil, si, pi)
	C.CloseHandle(outW[0])
	C.CloseHandle(inR[0])
	if okCreate == 0 then
		local err = C.GetLastError()
		C.CloseHandle(outR[0]) C.CloseHandle(inW[0])
		return nil, "could not start the chat helper (Windows error " .. tostring(err) .. ")"
	end
	local job = C.CreateJobObjectW(nil, nil)
	if job ~= nil then
		local info = ffi.new("PobChatJobExt")
		info.BasicLimitInformation.LimitFlags = KILL_ON_JOB_CLOSE
		C.SetInformationJobObject(job, JobObjectExtendedLimitInformation, info, ffi.sizeof(info))
		C.AssignProcessToJobObject(job, pi.hProcess)
	end
	C.ResumeThread(pi.hThread)
	C.CloseHandle(pi.hThread)
	return setmetatable({ proc = pi.hProcess, job = job, out = outR[0], stdin = inW[0], buf = "", lines = { }, running = true }, Proc)
end

function Proc:write(text)
	if not self.stdin then return false end
	local written = ffi.new("unsigned long[1]")
	local pos = 1
	while pos <= #text do
		local chunk = text:sub(pos, pos + 65535)
		if C.WriteFile(self.stdin, chunk, #chunk, written, nil) == 0 then return false end
		pos = pos + written[0]
	end
	return true
end

function Proc:closeInput()
	if self.stdin then C.CloseHandle(self.stdin) self.stdin = nil end
end

-- Read what is available without blocking; returns a list of complete lines.
function Proc:poll()
	local lines = { }
	if self.out then
		local avail = ffi.new("unsigned long[1]")
		local got = ffi.new("unsigned long[1]")
		for _ = 1, 16 do
			if C.PeekNamedPipe(self.out, nil, 0, nil, avail, nil) == 0 then
				-- Broken pipe: the process (and everything holding the pipe) is gone.
				C.CloseHandle(self.out) self.out = nil
				break
			end
			if avail[0] == 0 then break end
			local n = math.min(avail[0], 65536)
			local buf = ffi.new("char[?]", n)
			if C.ReadFile(self.out, buf, n, got, nil) == 0 then break end
			self.buf = self.buf .. ffi.string(buf, got[0])
		end
	end
	while true do
		local i = self.buf:find("\n", 1, true)
		if not i then break end
		table.insert(lines, (self.buf:sub(1, i - 1):gsub("\r$", "")))
		self.buf = self.buf:sub(i + 1)
	end
	if not self.out and self.running then
		if self.buf ~= "" then table.insert(lines, self.buf) self.buf = "" end
		self:finish()
	end
	return lines
end

function Proc:finish()
	if not self.running then return end
	self.running = false
	local code = ffi.new("unsigned long[1]")
	if self.proc ~= nil then
		C.WaitForSingleObject(self.proc, 200)
		if C.GetExitCodeProcess(self.proc, code) ~= 0 then self.exitCode = tonumber(code[0]) end
		C.CloseHandle(self.proc) self.proc = nil
	end
	if self.job ~= nil then C.CloseHandle(self.job) self.job = nil end
	self:closeInput()
end

-- End the process tree now.
function Proc:kill()
	if self.job ~= nil then C.TerminateJobObject(self.job, 1) end
	self:closeInput()
	if self.out then C.CloseHandle(self.out) self.out = nil end
	self.buf = ""
	self:finish()
end

return M
