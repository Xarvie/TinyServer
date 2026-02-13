
ø
Proto/Game.proto"A
	C2S_Login
account (	Raccount
password (	Rpassword"7
S2C_LoginResult
code (Rcode
uid (Ruid"D
C2S_Register
account (	Raccount
password (	Rpassword":
S2C_RegisterResult
code (Rcode
uid (Ruid"

C2S_Logout""
S2C_Kick
reason (Rreason"&
C2S_JoinRoom
roomId (	RroomId"<
S2C_JoinResult
code (Rcode
roomId (	RroomId"J
C2S_RoomAction

actionType (R
actionType
payload (	Rpayload"*
S2C_RoomSync
snapshot (	Rsnapshot";
C2S_UseItem
itemId (RitemId
count (Rcount"=
S2C_BagUpdate
itemId (RitemId
count (Rcount"(
C2S_Ping
	timestamp (R	timestamp"(
S2C_Pong
	timestamp (R	timestampbproto3