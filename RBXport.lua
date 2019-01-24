-- RBXport.lua
-- @author Validark
-- Run `lua RBXport` and it will tell you what to do

local FILE_NAME = "RBXport"
local RBXRefreshTask = [[{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "RbxRefresh",
            "command": "rbxrefresh",
            "args": ["${workspaceRoot}"],
            "type": "shell",
            "problemMatcher": [],
            "group": {
                "kind": "build",
                "isDefault": true
            }
        }
    ]
}
]]

local INVALID_FILE_CHARS = "[/\\:*?\"|<>]"

-- Makes the Folder if it doesn't exist
-- For whatever reason, still complains if it does exist
local function MakeFolder(Location)
	Location = "\"" .. Location .. "\""
	os.execute("IF NOT exist " .. Location .. "/nul ( mkdir " .. Location .. " )")
end

-- Returns the Source at Directory
local function GetFileSource(Directory)
	local Original = assert(io.open(Directory, "r"))
	local Source = Original:read("*all")
	Original:close()
	return Source
end

-- Creates a File at Location with Source
-- Creates the Folder it should be in if it doesn't exist
local function WriteToFile(Location, Source)
	MakeFolder(Location:gsub("\\[^\\]+$", ""))
	local Success, File = pcall(io.open, Location, "w")

	if Success and File then
		File:write(Source)
		File:flush()
		File:close()
	else
		print(Location, debug.traceback())
	end
end

local function InvertTable(t)
	local o = {}
	for i, v in next, t do
		o[v] = i
	end
	return o
end

-- Creates the Variables necessary to convert back and forth to HTML escape/unescape
local EscapableString, HTMLEscapes, UnescapableString, HTMLUnescapes do
	-- String:gsub(EscapableString, HTMLEscapes)
	-- String:gsub(UnescapableString, HTMLUnescapes)

	HTMLEscapes = {
		["<"] = "&lt;"; [" "] = "&nbsp;"; ["/"] = "&sol;"; ["±"] = "&plusmn;";
		[">"] = "&gt;"; ["¡"] = "&iexcl;"; [":"] = "&colon;"; ["²"] = "&sup2;";
		["!"] = "&excl;"; ["¢"] = "&cent;"; [";"] = "&semi;"; ["³"] = "&sup3;";
		["“"] = "&quot;"; ["£"] = "&pound;"; ["="] = "&equals;"; ["´"] = "&acute;";
		["#"] = "&num;"; ["¤"] = "&curren;"; ["?"] = "&quest;"; ["µ"] = "&micro;";
		["$"] = "&dollar;"; ["¥"] = "&yen;"; ["@"] = "&commat;"; ["¶"] = "&para;";
		["%"] = "&percnt;"; ["¦"] = "&brkbar;"; ["["] = "&nbsp;&lsqb;"; ["·"] = "&middot;";
		["&"] = "&amp;"; ["§"] = "&sect;"; ["\\"] = "&bsol;"; ["¸"] = "&cedil;";
		["‘"] = "&apos;"; ["¨"] = "&uml;"; ["]"] = "&rsqb;"; ["¹"] = "&sup1;";
		["("] = "&lpar;"; ["©"] = "&copy;"; ["^"] = "&caret;"; ["º"] = "&ordm;";
		[")"] = "&rpar;"; ["ª"] = "&ordf;"; ["_"] = "&lowbar;"; ["»"] = "&raquo;";
		["*"] = "&ast;"; ["«"] = "&laquo;"; ["{"] = "&lcub;"; ["¼"] = "&frac14;";
		["+"] = "&plus;"; ["¬"] = "&not;"; ["|"] = "&verbar;"; ["½"] = "&half;";
		[","] = "&comma;"; ["®"] = "&reg;"; ["}"] = "&rcub;"; ["¾"] = "&frac34;";
		["–"] = "&dash;"; ["¯"] = "&hibar;"; ["~"] = "&tilde;"; ["¿"] = "&iquest;";
		["."] = "&period;"; ["°"] = "&deg;";
	}

	local Escapable = "([%" .. table.concat({"%", "^", "$", "(", ")", ".", "[", "]", "*", "+", "-", "?"}, "%") .. "])"
	EscapableString = "["

	for Char in next, HTMLEscapes do
		EscapableString = EscapableString .. Char:gsub(Escapable, "%%%1")
	end

	EscapableString = EscapableString .. "]"
	UnescapableString = "&%l+%d*;"
	HTMLUnescapes = InvertTable(HTMLEscapes)
end

-- Helper for MatchBalanced to know what position to skip to
local CaptureStarts = setmetatable({}, {
	__index = function(self, i)
		self[i] = i:find("%b", 1, true) - 1
		return self[i]
	end
})

-- Helper function which basically captures the inside of a %b capture
	-- assumes anchoring to the front of the String (at Pos)
	-- assumes a single capture
local function MatchBalanced(Str, Pattern, Pos, Bool)
	local a, b = Str:find("^" .. Pattern, Pos, Bool)
	if a then return Str:sub(CaptureStarts[Pattern] + a + 1, b - 1), a, b end
end

-- Gets the NextTag for a given Position
local function NextTag(Source, Position)
	local _, e = Source:find("%s*", Position + 1)
	Position = (e or Position) + 1
	local a, b, Str = Source:find("^<!%[CDATA%[(.-)%]%]>", Position) -- Handling ProtectedStrings can be complicated, so we use a special case

	if a then
		return b, Str, "Tag"
	else
		Str, a, b = MatchBalanced(Source, "%b<>", Position)

		if a then
			return b, Str, "Tag"
		else
			local c, d = Source:find("^[^<]+", Position)
			if c then
				return d, Source:sub(c, d), "Literal"
			end
		end
	end
end

--[[
Returns our stateful Next() function
Type is a string: either "Tag" or "Literal"
Value is a string which is whatever it is

Example parse:
<code>4</code>
1: Next() - "code", "Tag"
2: Next() - "4", "Literal"
3: Next() - "/code", "Tag"
--]]
local function GetXMLParser(Directory)
	return coroutine.wrap(function()
		for _, Value, Type in NextTag, GetFileSource(Directory), 0 do
			coroutine.yield(Value, Type)
		end
	end)
end

local Ending = {
	Script = ".server.lua";
	LocalScript = ".client.lua";
	ModuleScript = ".module.lua";
	LocalizationTable = ".csv";
	StringValue = ".txt";
}

local function CompileErrorData(Location, Object)
	local PropertyCompile = {}
	for i, v in next, Object do
		table.insert(PropertyCompile, tostring(i) .. " = " .. tostring(v))
	end
	return "\n\nLocation: " .. Location .. "\nProperties: " .. "{\n\t" .. table.concat(PropertyCompile, ";\n\t") .. "\n}\n"
end

local function BuildProject(Directory, Tree)
	local MadeStuff = false

	local function CallOnChildren(Location, Object)
		-- Instantiate Object at Location
		local Name = Object.Name

		if not Name or Name:find(INVALID_FILE_CHARS) then
			error(tostring(Name) .. " is an invalid name and cannot be written to a local file." .. CompileErrorData(Location, Object))
		end

		local ClassName = Object.ClassName
		local Children = Object.Children
		local IsScript = ClassName == "Script" or ClassName == "LocalScript" or ClassName == "ModuleScript"

		if IsScript then
			MadeStuff = true
			WriteToFile(Location .. "\\" .. Name .. Ending[ClassName], Object.Source or "")
		end

		-- Do so for Children
		for i = 1, #Children do
			CallOnChildren(Location .. "\\" .. Name, Children[i])
		end
	end

	CallOnChildren(Directory, Tree)

	if MadeStuff then
		WriteToFile(Directory .. "\\.vscode\\tasks.json", RBXRefreshTask)
	else
		print("No scripts to instantiate!")
	end
end

-- Helper error function
local function Unexpected(Expected, Value, Type)
	error("Expected " .. Expected .. ", got " .. Type .. " " .. Value, 3)
end

-- Makes sure a (Value, Type) is of the ExpectedType
local function assertType(ExpectedType, Value, Type)
	if Type ~= ExpectedType then
		Unexpected(ExpectedType, Value, Type)
	end
	return Value, Type
end

-- Makes sure a (Value, Type) is a Tag and is the ExpectedTag
local function assertTag(ExpectedTag, Value, Type)
	if Type ~= "Tag" then
		Unexpected("Tag", Value, Type)
	elseif Value ~= ExpectedTag then
		Unexpected(ExpectedTag, Value, Type)
	end
	return Value, Type
end

-- Expects a single literal, with no literal meaning nil
local function SingleLiteral(Next, Closer)
	local Value, Type = Next()

	if Type == "Literal" then
		assertTag(Closer, Next())
	else
		if Value == Closer then
			Value = nil
		else
			assertTag(Closer, Next())
		end
	end

	return Value, Type
end

local function ExpectFields(DataType, t)
	local n = #t
	local Init = DataType .. ".new("

	return function(Next, Closer)
		local r = {}

		for i = 1, n do
			local d = t[i]
			assertTag(d, Next())
			r[i] = assertType("Literal", Next())
			assertTag("/" .. d, Next())
		end

		assertTag(Closer, Next())
		return Init .. table.concat(r, ", ") .. ")"
	end
end

local function GetSpaceSeparatedLiterals(Next, Closer)
	local Value, Type = Next()
	assertType("Literal", Value, Type)

	local Parameters = {}

	for Num in Value:gmatch("%S+") do
		table.insert(Parameters, Num)
	end

	assertTag(Closer, Next())
	return Parameters
end

-- The table which contains functions which process different Types
-- Functions take in `(Next, Closer)`.
-- `Closer` is a string, which is the Tag that opened the function, but with a "/" added at the beginning
-- This helps me reuse functions like SingleLiteral.
-- `Next` is a stateful function which advances the XML parser.
	-- It returns `Value, Type`, where `Type` is "Tag" or "Literal" and Value is a string of whatever the parser is currently on,
	-- excluding the signs `<>` surrounding signs.
local TypeProcess = setmetatable({
	ProtectedString = function(Next, Closer)
		local Value, Type = SingleLiteral(Next, Closer)

		if Type == "Literal" then
			Value = Value:gsub(UnescapableString, HTMLUnescapes)
		end

		return Value
	end;

	bool = SingleLiteral;
	token = SingleLiteral;
	string = SingleLiteral;
	Ref = SingleLiteral;
	double = SingleLiteral;
	float = SingleLiteral;
	int = SingleLiteral;
	int64 = SingleLiteral;

	BinaryString = function(Next)
		while Next() ~= "/BinaryString" do end
	end;

	CoordinateFrame = ExpectFields("CFrame", {"X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22"});
	Faces = ExpectFields("Faces", {"faces"});

	Color3uint8 = function(Next, Closer)
		local B = tonumber((assertType("Literal", Next())))
		local _ = (B - B % 0x01000000) / 0x01000000
		B = B - _ * 0x01000000
		local R = (B - B % 0x00010000) / 0x00010000
		B = B - R * 0x00010000
		local G = (B - B % 0x00000100) / 0x00000100
		B = B - G * 0x00000100
		assertTag(Closer, Next())
		return "Color3.fromRGB(" .. R .. ", " .. G .. ", " .. B .. ")"
	end;

	PhysicalProperties = function(Next)
		local Props = {}
		local Value = assertType("Tag", Next())
		repeat
			Props[Value] = assertType("Literal", Next())
			assertTag("/" .. Value, Next())
			Value = assertType("Tag", Next())
		until Value == "/PhysicalProperties"
		return Props
	end;

	Vector3 = ExpectFields("Vector3", {"X", "Y", "Z"});

	Color3 = function(Next)
		local B = tonumber((Next()))
		local _ = (B - B % 0x01000000) / 0x01000000
		B = B - _ * 0x01000000
		local R = (B - B % 0x00010000) / 0x00010000
		B = B - R * 0x00010000
		local G = (B - B % 0x00000100) / 0x00000100
		B = B - G * 0x00000100
		assertTag("/Color3", Next())
		return "Color3.fromRGB(" .. R .. ", " .. G .. ", " .. B .. ")"
	end;

	Content = function(Next)
		local Value = assertType("Tag", Next())
		local v
		if Value == "url" then
			v = tostring((assertType("Literal", Next())))
		elseif Value == "null" then
			v = nil
		else
			error("No implementation for Content = " .. Value)
		end

		assertTag("/" .. Value, Next())
		assertTag("/Content", Next())

		return v
	end;

	Axes = function(Next)
		while Next() ~= "/Axes" do end
	end;

	Vector2 = ExpectFields("Vector2", {"X", "Y"});
	UDim2 = ExpectFields("UDim2", {"XS", "XO", "YS", "YO"});

	Rect2D = function(Next, Closer)
		local x = {"min", "max"}
		local t = {"X", "Y"}

		local r = {}

		for a = 1, #x do
			assertTag(x[a], Next())
			for i = 1, #t do
				assertTag(t[i], Next())
				r[i] = assertType("Literal", Next())
				assertTag("/" .. t[i], Next())
			end
			assertTag("/" .. x[a], Next())
		end
		assertTag(Closer, Next())
		return "Rect.new(" .. table.concat(r, ", ") .. ")"
	end;

	ColorSequence = function(...)
		return "ColorSequence.new{" .. table.concat(GetSpaceSeparatedLiterals(...), ", ") .. "}"
	end;

	NumberRange = function(...)
		return "NumberRange.new(" .. table.concat(GetSpaceSeparatedLiterals(...), ", ") .. ")"
	end;

	NumberSequence = function(...)
		return "NumberSequence.new(" .. table.concat(GetSpaceSeparatedLiterals(...), ", ") .. ")"
	end;
}, {
	__index = function(_, i)
		error(i .. " needs an implementation")
	end;
})

local EnterObject

-- If the current Value starts with "Item class=", start interpreting it
local function EnterObjectIfClass(Value, Objects, Next)
	if Value then
		local ClassName = MatchBalanced(Value, "Item class=%b\"\"")

		if ClassName then
			EnterObject(ClassName, Objects, Next)
		end

		return Value
	end
end

-- Found an Object! Start interpreting its properties
function EnterObject(ClassName, Parent, Next)
	local self = {Children = {}; Parent = Parent; ClassName = ClassName}
	table.insert(Parent.Children, self)
	local Value = Next()

	while Value ~= "/Item" do
		if Value == "Properties" then
			Value = Next()
			while Value ~= "/Properties" do
				local _, b, PropertyType = Value:find("^(%S+)")
				local Property = MatchBalanced(Value, "name=%b\"\"", b + 2)
				self[Property] = TypeProcess[PropertyType](Next, "/" .. PropertyType)
				Value = Next()
			end
		else
			EnterObjectIfClass(Value, self, Next)
		end
		Value = Next()
	end
end

-- Constuct a Tree of all Objects in the game, (enter `Children`)
local function MakeTree(Directory)
	local Next = GetXMLParser(Directory)
	local Objects = {Children = {}; ClassName = "DataModel"; Name = "src"}
	while EnterObjectIfClass(Next(), Objects, Next) do end
	return Objects
end

-- Simple extendable command line program
local Dash = ("-"):byte()

local function Main(arc, argv)
	local Parameters = {}
	local FlagsPresent = {}

	for i = 1, arc do
		local v = argv[i]

		if v:byte() == Dash then
			FlagsPresent[v:lower()] = true
		else
			table.insert(Parameters, v)
		end
	end

	if arc == 0 or FlagsPresent["--h"] or FlagsPresent["--help"] then
		print(FILE_NAME .. " not run! Displaying help message:")
		print("\"" .. FILE_NAME .. " expects arguments of the form:\n\t>lua " .. FILE_NAME .. ".lua PATH_TO_FILE.rbxlx FOLDER_PATH_TO_WRITE_TO\n")
	else
		-- Validate input
		local t1 = os.clock()
		print("Constructing Object tree from " .. Parameters[1])
		print("This could take upwards of a minute for large files.")
		local Objects = MakeTree(Parameters[1]:gsub("/", "\\"))
		print("Completed Object tree. Took " .. (os.clock() - t1) .. " seconds.")
		print("Instantiating Files at location: " .. Parameters[2])
		BuildProject(Parameters[2]:gsub("/", "\\"), Objects)
		print("Completed!")
	end
end

Main(select("#", ...), {...})
