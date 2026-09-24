class_name Events
## Notable events to jump to: the fetch panel's "Notable events" list and `event=<id>` (a
## permalink on web). Each is one radar's loop around the event (every archive volume from
## `from` to `to`, UTC), opening at `peak`. Times are checked against the archive listing.

const LIST: Array[Dictionary] = [
	{
		"id": "jarrell1997",
		"name": "Jarrell F5, 1997",
		"site": "KEWX",
		"from": "1997-05-27T20:00Z",
		"to": "1997-05-27T21:30Z",
		"peak": "1997-05-27T20:40Z",
		"note": "Central Texas; the radar is 95 km south. Legacy (Message 1) data.",
	},
	{
		"id": "moore1999",
		"name": "Bridge Creek-Moore F5, 1999",
		"site": "KTLX",
		"from": "1999-05-03T22:30Z",
		"to": "1999-05-04T00:45Z",
		"peak": "1999-05-04T00:05Z",
		"note": "May 3 outbreak, through south Oklahoma City. Legacy (Message 1) data.",
	},
	{
		"id": "katrina2005",
		"name": "Hurricane Katrina, 2005",
		"site": "KLIX",
		"from": "2005-08-29T09:00Z",
		"to": "2005-08-29T12:00Z",
		"peak": "2005-08-29T11:10Z",
		"note": "Landfall at Buras, Louisiana, 11:10Z; the eyewall nears the radar.",
	},
	{
		"id": "greensburg2007",
		"name": "Greensburg EF5, 2007",
		"site": "KDDC",
		"from": "2007-05-05T01:30Z",
		"to": "2007-05-05T03:00Z",
		"peak": "2007-05-05T02:45Z",
		"note": "The first EF5; Greensburg, Kansas at 02:45Z. Legacy (Message 1) data.",
	},
	{
		"id": "tuscaloosa2011",
		"name": "Tuscaloosa-Birmingham EF4, 2011",
		"site": "KBMX",
		"from": "2011-04-27T21:45Z",
		"to": "2011-04-27T23:45Z",
		"peak": "2011-04-27T22:13Z",
		"note": "April 27 super outbreak; Tuscaloosa at 22:13Z.",
	},
	{
		"id": "joplin2011",
		"name": "Joplin EF5, 2011",
		"site": "KSGF",
		"from": "2011-05-22T22:00Z",
		"to": "2011-05-22T23:15Z",
		"peak": "2011-05-22T22:41Z",
		"note": "Joplin, Missouri at 22:41Z, 100 km west of the radar.",
	},
	{
		"id": "moore2013",
		"name": "Moore EF5, 2013",
		"site": "KTLX",
		"from": "2013-05-20T19:30Z",
		"to": "2013-05-20T20:45Z",
		"peak": "2013-05-20T20:10Z",
		"note": "Newcastle to Moore, 19:56-20:35Z, passing 15 km from the radar.",
	},
	{
		"id": "elreno2013",
		"name": "El Reno, 2013",
		"site": "KTLX",
		"from": "2013-05-31T22:45Z",
		"to": "2013-05-31T23:55Z",
		"peak": "2013-05-31T23:20Z",
		"note": "The widest tornado on record (4.2 km), 23:03-23:43Z.",
	},
	{
		"id": "harvey2017",
		"name": "Hurricane Harvey, 2017",
		"site": "KCRP",
		"from": "2017-08-26T00:30Z",
		"to": "2017-08-26T04:00Z",
		"peak": "2017-08-26T03:00Z",
		"note": "Category 4 landfall near Rockport, Texas, 03:00Z.",
	},
	{
		"id": "michael2018",
		"name": "Hurricane Michael, 2018",
		"site": "KEVX",
		"from": "2018-10-10T15:30Z",
		"to": "2018-10-10T18:30Z",
		"peak": "2018-10-10T17:30Z",
		"note": "Category 5 landfall at Mexico Beach, Florida, 17:30Z.",
	},
	{
		"id": "derecho2020",
		"name": "Iowa derecho, 2020",
		"site": "KDMX",
		"from": "2020-08-10T15:30Z",
		"to": "2020-08-10T17:30Z",
		"peak": "2020-08-10T16:45Z",
		"note": "A bow echo crossing Iowa with 60 m/s gusts.",
	},
	{
		"id": "ida2021",
		"name": "Hurricane Ida, 2021",
		"site": "KLIX",
		"from": "2021-08-29T15:00Z",
		"to": "2021-08-29T18:00Z",
		"peak": "2021-08-29T16:55Z",
		"note": "Landfall at Port Fourchon, Louisiana, 16:55Z.",
	},
	{
		"id": "mayfield2021",
		"name": "Mayfield EF4, 2021",
		"site": "KPAH",
		"from": "2021-12-11T02:30Z",
		"to": "2021-12-11T04:15Z",
		"peak": "2021-12-11T03:26Z",
		"note": "The Quad-State tornado; Mayfield, Kentucky at 03:26Z.",
	},
	{
		"id": "ian2022",
		"name": "Hurricane Ian, 2022",
		"site": "KTBW",
		"from": "2022-09-28T16:30Z",
		"to": "2022-09-28T19:30Z",
		"peak": "2022-09-28T19:05Z",
		"note": "Landfall at Cayo Costa, Florida, 19:05Z, 150 km south of the radar.",
	},
	{
		"id": "buffalo2022",
		"name": "Buffalo lake-effect snow, 2022",
		"site": "KBUF",
		"from": "2022-11-18T12:00Z",
		"to": "2022-11-18T15:00Z",
		"peak": "2022-11-18T13:30Z",
		"note": "A Lake Erie band that buried the south towns under up to 2 m in three days.",
	},
	{
		"id": "rollingfork2023",
		"name": "Rolling Fork EF4, 2023",
		"site": "KDGX",
		"from": "2023-03-25T00:30Z",
		"to": "2023-03-25T01:45Z",
		"peak": "2023-03-25T01:02Z",
		"note": "Rolling Fork, Mississippi at 01:02Z.",
	},
]


## The event with `id`, or {}.
static func find(id: String) -> Dictionary:
	for e in LIST:
		if e["id"] == id:
			return e
	return {}


## Unix time of an event time ("2013-05-20T20:10Z").
static func unix(iso: String) -> int:
	var t := iso.trim_suffix("Z")
	return Time.get_unix_time_from_datetime_string(t + ":00" if t.length() == 16 else t)


## Starts fetching `event`'s loop; main follows it as it arrives (takes_over) and jumps to its
## peak when the job finishes ("jump_to"). The caller sets the window (main._set_window).
static func start(event: Dictionary, fetcher: Fetcher) -> Fetcher.Job:
	var job := fetcher.start_update(event["site"], "", event["from"], event["to"])
	if job != null:
		job.set_meta("jump_to", unix(event["peak"]))
	return job


## The site to open on: `want` (site=, defaulted from event=) if cached or the event's own
## (whose fetch is about to start), else "" for the caller's fallback, the latest site.
static func startup_site(event: Dictionary, want: String, sites: Array[String]) -> String:
	if sites.has(want) or (not want.is_empty() and want == event.get("site", "")):
		return want
	return ""


## Whether the scan `name` just written by a fetch (oldest first) takes over from the frame on
## screen (`shown`, "" for none): it does when it is nearer the fetch's target (`peak`: an
## event's peak, else the window's end), so the view converges on it even if the fetch fails
## or is stopped part way, and a fetch that re-reports cached scans never moves it off the
## target. The event's own window (TimeWindow.of_event) keeps the site's other scans out.
static func takes_over(peak: int, name: String, shown: String) -> bool:
	if shown.is_empty():
		return true
	return absi(RadarLibrary.unix_of(name) - peak) < absi(RadarLibrary.unix_of(shown) - peak)
