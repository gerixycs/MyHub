local Framework = {}

function Framework.PrintTable(
    tbl: {[any]: any},
    indent: number?,
    seen: {[any]: boolean}?
)
    indent = indent or 0
    seen = seen or {}

    if seen[tbl] then
        print(`{string.rep(" ", indent)}<already visited>`)
        return
    end

    seen[tbl] = true

    for key, value in tbl do
        local prefix = `{string.rep(" ", indent)}{tostring(key)} = `

        if type(value) == "table" then
            print(prefix .. "{")
            Framework.PrintTable(value, indent + 2, seen)
            print(string.rep(" ", indent) .. "}")
        else
            print(`{prefix}{tostring(value)}`)
        end
    end
end

return Framework
