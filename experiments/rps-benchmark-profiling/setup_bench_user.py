#!/usr/bin/env python3
"""
setup_bench_user.py
Manages dummy benchmark user pool and API keys for Frappe Framework instances.
Runs inside a Frappe pod (bench container) to provision or clean up test accounts.
"""

import sys
import os
import json
import secrets

def get_db_user():
    import frappe
    site = os.environ.get("BENCH_SITE", "frappe.local")
    frappe.init(site)
    frappe.connect()

    num_users = int(os.environ.get("BENCH_NUM_USERS", "100"))
    action = os.environ.get("BENCH_ACTION", "create") # create or cleanup

    base_email = "loadtest_{i}@example.com"
    base_name = "Load Test User {i}"
    password = "BenchPassword123!"

    if action == "cleanup":
        print(f"[*] Cleaning up {num_users} benchmark users...")
        for i in range(1, num_users + 1):
            email = base_email.format(i=i)
            if frappe.db.exists("User", email):
                frappe.delete_doc("User", email, force=True, ignore_permissions=True)
                frappe.db.commit()
        # Clean up any leftover test ToDos
        todos = frappe.get_all("ToDo", filters={"description": ["like", "Benchmark test task%"]})
        for t in todos:
            frappe.delete_doc("ToDo", t.name, force=True, ignore_permissions=True)
        frappe.db.commit()
        print("[+] Cleanup complete.")
        return []

    # Provision or retrieve users
    users = []
    for i in range(1, num_users + 1):
        email = base_email.format(i=i)
        user_doc = None
        if not frappe.db.exists("User", email):
            user_doc = frappe.get_doc({
                "doctype": "User",
                "email": email,
                "first_name": base_name.format(i=i),
                "enabled": 1,
                "new_password": password,
                "roles": [{"doctype": "Has Role", "role": "System Manager"}]
            })
            user_doc.insert(ignore_permissions=True)
            frappe.db.commit()
        else:
            user_doc = frappe.get_doc("User", email)

        # Ensure API key & secret
        api_key = user_doc.api_key
        api_secret = user_doc.get_password("api_secret")

        if not api_key:
            api_key = secrets.token_hex(15)
            user_doc.api_key = api_key
            user_doc.save(ignore_permissions=True)
            frappe.db.commit()

        if not api_secret:
            api_secret = secrets.token_hex(15)
            user_doc.set_password("api_secret", api_secret)
            user_doc.save(ignore_permissions=True)
            frappe.db.commit()

        users.append({
            "email": email,
            "password": password,
            "api_key": api_key,
            "api_secret": api_secret
        })

    return users

if __name__ == "__main__":
    try:
        users = get_db_user()
        print(json.dumps({"status": "success", "count": len(users), "users": users}))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}), file=sys.stderr)
        sys.exit(1)
