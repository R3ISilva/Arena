-- Wire encoding for session messages. Payloads are JSON so they are easy to
-- inspect and test; the game-session module only ever sees decoded tables.

local json = require("json")

local protocol = {}

function protocol.encode(message)
    return json.encode(message)
end

function protocol.decode(payload)
    return json.decode(payload)
end

return protocol
