local Framework = {}

function Framework.PrintTable(table: {[any]: any}, indent: number?, seen: {[any]: boolean}?)
    indent = indent or 0
    seen = seen or {}

    if seen[table] then
        print(`{string.rep(" ", indent)}<already visited>`)
        return
    end

    seen[table] = true

    for key, value in table do
        local prefix = `{string.rep(" ", indent)}{tostring(key)} = `

        if type(value) == "table" then
            print(`{prefix}\{`)
            PrintTable(value, indent + 2, seen)
            print(`{string.rep(" ", indent)}\}`)
        else
            print(`{prefix}{tostring(value)}`)
        end
    end
end

return Framework
