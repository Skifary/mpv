local utils = require 'mp.utils'
local msg = require 'mp.msg'

local ytdl = {
    path = "youtube-dl",
    searched = false
}

local chapter_list = {}

local function exec(args)
    local ret = utils.subprocess({args = args})
    return ret.status, ret.stdout, ret
end

-- return true if it was explicitly set on the command line
local function option_was_set(name)
    return mp.get_property_bool("option-info/" ..name.. "/set-from-commandline",
                                false)
end

-- youtube-dl may set special http headers for some sites (user-agent, cookies)
local function set_http_headers(http_headers)
    if not http_headers then
        return
    end
    local headers = {}
    local useragent = http_headers["User-Agent"]
    if useragent and not option_was_set("user-agent") then
        mp.set_property("file-local-options/user-agent", useragent)
    end
    local additional_fields = {"Cookie", "Referer"}
    for idx, item in pairs(additional_fields) do
        local field_value = http_headers[item]
        if field_value then
            headers[#headers + 1] = item .. ": " .. field_value
        end
    end
    if #headers > 0 and not option_was_set("http-header-fields") then
        mp.set_property_native("file-local-options/http-header-fields", headers)
    end
end

local function append_rtmp_prop(props, name, value)
    if not name or not value then
        return props
    end

    if props and props ~= "" then
        props = props..","
    else
        props = ""
    end

    return props..name.."=\""..value.."\""
end

local function edl_escape(url)
    return "%" .. string.len(url) .. "%" .. url
end

local function time_to_secs(time_string)
    local ret

    local a, b, c = time_string:match("(%d+):(%d%d?):(%d%d)")
    if a ~= nil then
        ret = (a*3600 + b*60 + c)
    else
        a, b = time_string:match("(%d%d?):(%d%d)")
        if a ~= nil then
            ret = (a*60 + b)
        end
    end

    return ret
end

local function extract_chapters(data, video_length)
    local ret = {}

    for line in data:gmatch("[^\r\n]+") do
        local time = time_to_secs(line)
        if time and (time < video_length) then
            table.insert(ret, {time = time, title = line})
        end
    end
    table.sort(ret, function(a, b) return a.time < b.time end)
    return ret
end


mp.add_hook("on_load", 10, function ()
    local url = mp.get_property("stream-open-filename")

    if (url:find("http://") == 1) or (url:find("https://") == 1)
        or (url:find("ytdl://") == 1) then

        -- check for youtube-dl in mpv's config dir
        if not (ytdl.searched) then
            local ytdl_mcd = mp.find_config_file("youtube-dl")
            if not (ytdl_mcd == nil) then
                msg.verbose("found youtube-dl at: " .. ytdl_mcd)
                ytdl.path = ytdl_mcd
            end
            ytdl.searched = true
        end

        -- strip ytdl://
        if (url:find("ytdl://") == 1) then
            url = url:sub(8)
        end

        local format = mp.get_property("options/ytdl-format")
        local raw_options = mp.get_property_native("options/ytdl-raw-options")
        local allsubs = true

        local command = {
            ytdl.path, "--no-warnings", "-J", "--flat-playlist",
            "--sub-format", "ass/srt/best", "--no-playlist"
        }

        -- Checks if video option is "no", change format accordingly,
        -- but only if user didn't explicitly set one
        if (mp.get_property("options/vid") == "no")
            and not option_was_set("ytdl-format") then

            format = "bestaudio"
            msg.verbose("Video disabled. Only using audio")
        end

        if (format == "") then
            format = "bestvideo+bestaudio"
        end
        table.insert(command, "--format")
        table.insert(command, string.format('(%s)[protocol!=http_dash_segments]/best', format))

        for param, arg in pairs(raw_options) do
            table.insert(command, "--" .. param)
            if (arg ~= "") then
                table.insert(command, arg)
            end
            if (param == "sub-lang") and (arg ~= "") then
                allsubs = false
            end
        end

        if (allsubs == true) then
            table.insert(command, "--all-subs")
        end
        table.insert(command, "--")
        table.insert(command, url)
        msg.debug("Running: " .. table.concat(command,' '))
        local es, json, result = exec(command)

        if (es < 0) or (json == nil) or (json == "") then
            if not result.killed_by_us then
                msg.warn("youtube-dl failed, trying to play URL directly ...")
            end
            return
        end

        local json, err = utils.parse_json(json)

        if (json == nil) then
            msg.error("failed to parse JSON data: " .. err)
            return
        end

        msg.verbose("youtube-dl succeeded!")

        -- what did we get?
        if not (json["direct"] == nil) and (json["direct"] == true) then
            -- direct URL, nothing to do
            msg.verbose("Got direct URL")
            return
        elseif not (json["_type"] == nil)
            and ((json["_type"] == "playlist")
            or (json["_type"] == "multi_video")) then
            -- a playlist

            if (#json.entries == 0) then
                msg.warn("Got empty playlist, nothing to play.")
                return
            end


            -- some funky guessing to detect multi-arc videos
            if (not (json.entries[1]["_type"] == "url_transparent")) and
                (not (json.entries[1]["webpage_url"] == nil)
                and (json.entries[1]["webpage_url"] == json["webpage_url"])) then
                msg.verbose("multi-arc video detected, building EDL")

                local playlist = "edl://"
                for i, entry in pairs(json.entries) do
                    playlist = playlist .. edl_escape(entry.url)
                    if not (entry.duration == nil) then
                        playlist = playlist..",start=0,length="..entry.duration
                    end
                    playlist = playlist .. ";"
                end

                msg.debug("EDL: " .. playlist)

                -- can't change the http headers for each entry, so use the 1st
                if json.entries[1] then
                    set_http_headers(json.entries[1].http_headers)
                end

                mp.set_property("stream-open-filename", playlist)
                if not (json.title == nil) then
                    mp.set_property("file-local-options/force-media-title",
                        json.title)
                end

                -- there might not be subs for the first segment
                local entry_wsubs = nil
                for i, entry in pairs(json.entries) do
                    if not (entry.requested_subtitles == nil) then
                        entry_wsubs = i
                        break
                    end
                end

                if not (entry_wsubs == nil) and
                    not (json.entries[entry_wsubs].duration == nil) then
                    for j, req in pairs(json.entries[entry_wsubs].requested_subtitles) do
                        local subfile = "edl://"
                        for i, entry in pairs(json.entries) do
                            if not (entry.requested_subtitles == nil) and
                                not (entry.requested_subtitles[j] == nil) then
                                subfile = subfile..edl_escape(entry.requested_subtitles[j].url)
                            else
                                subfile = subfile..edl_escape("memory://WEBVTT")
                            end
                            subfile = subfile..",start=0,length="..entry.duration..";"
                        end
                        msg.debug(j.." sub EDL: "..subfile)
                        mp.commandv("sub-add", subfile, "auto", req.ext, j)
                    end
                end

            else

                local playlist = "#EXTM3U\n"
                for i, entry in pairs(json.entries) do
                    local site = entry.url
                    local title = entry.title

                    if not (title == nil) then
                        title = string.gsub(title, '%s+', ' ')
                        playlist = playlist .. "#EXTINF:0," .. title .. "\n"
                    end

                    -- some extractors will still return the full info for
                    -- all clips in the playlist and the URL will point
                    -- directly to the file in that case, which we don't
                    -- want so get the webpage URL instead, which is what
                    -- we want
                    if not (json.entries[1]["_type"] == "url_transparent")
                        and not (entry["webpage_url"] == nil) then
                        site = entry["webpage_url"]
                    end

                    playlist = playlist .. "ytdl://" .. site .. "\n"
                end

                mp.set_property("stream-open-filename", "memory://" .. playlist)
            end

        else -- probably a video
            local streamurl = ""

            -- DASH?
            if not (json["requested_formats"] == nil) then
                if (json["requested_formats"][1].protocol == "http_dash_segments") then
                    msg.error("MPEG-Dash Segments unsupported, add [protocol!=http_dash_segments] to your ytdl-format.")
                    return
                end

                -- video url
                streamurl = json["requested_formats"][1].url

                -- audio url
                mp.commandv("audio-add", json["requested_formats"][2].url,
                    "select", json["requested_formats"][2]["format_note"] or "")

            elseif not (json.url == nil) then
                -- normal video
                streamurl = json.url
                set_http_headers(json.http_headers)
            else
                msg.error("No URL found in JSON data.")
                return
            end

            msg.debug("streamurl: " .. streamurl)

            mp.set_property("stream-open-filename", streamurl)

            mp.set_property("file-local-options/force-media-title", json.title)

            -- add subtitles
            if not (json.requested_subtitles == nil) then
                for lang, sub_info in pairs(json.requested_subtitles) do
                    msg.verbose("adding subtitle ["..lang.."]")

                    local sub = nil

                    if not (sub_info.data == nil) then
                        sub = "memory://"..sub_info.data
                    elseif not (sub_info.url == nil) then
                        sub = sub_info.url
                    end

                    if not (sub == nil) then
                        mp.commandv("sub-add", sub,
                            "auto", sub_info.ext, lang)
                    else
                        msg.verbose("No subtitle data/url for ["..lang.."]")
                    end
                end
            end

            -- add chapters from description
            if not (json.description == nil) and not (json.duration == nil) then
                chapter_list = extract_chapters(json.description, json.duration)
            end

            -- set start time
            if not (json.start_time == nil) then
                msg.debug("Setting start to: " .. json.start_time .. " secs")
                mp.set_property("file-local-options/start", json.start_time)
            end

            -- set aspect ratio for anamorphic video
            if not (json.stretched_ratio == nil) and
                not option_was_set("video-aspect") then
                mp.set_property('file-local-options/video-aspect', json.stretched_ratio)
            end

            -- for rtmp
            if (json.protocol == "rtmp") then
                local rtmp_prop = append_rtmp_prop(nil,
                    "rtmp_tcurl", streamurl)
                rtmp_prop = append_rtmp_prop(rtmp_prop,
                    "rtmp_pageurl", json.page_url)
                rtmp_prop = append_rtmp_prop(rtmp_prop,
                    "rtmp_playpath", json.play_path)
                rtmp_prop = append_rtmp_prop(rtmp_prop,
                    "rtmp_swfverify", json.player_url)
                rtmp_prop = append_rtmp_prop(rtmp_prop,
                    "rtmp_app", json.app)

                mp.set_property("file-local-options/stream-lavf-o", rtmp_prop)
            end
        end
    end
end)


mp.add_hook("on_preloaded", 10, function ()
    if next(chapter_list) ~= nil then
        msg.verbose("Setting chapters from video's description")

        mp.set_property_native("chapter-list", chapter_list)
        chapter_list = {}
    end
end)
