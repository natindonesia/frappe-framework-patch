def post_fork(server, worker):
	try:
		from frappe.otel import boot

		boot()
	except Exception:
		# boot() handles its own errors; this guards only the import above.
		server.log.exception("frappe.otel post_fork boot failed")
