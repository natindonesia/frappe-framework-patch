#!/usr/bin/env python3
"""
setup_bench_user.py
Manages dummy benchmark user pool and API keys for fayolex-working-staging Frappe instance.
"""

import os
import sys
import json

if os.path.exists('/home/frappe/frappe-bench/sites'):
    os.chdir('/home/frappe/frappe-bench/sites')

import frappe
from frappe.core.doctype.user.user import generate_keys
from frappe.utils.password import update_password

site = os.environ.get("BENCH_SITE", "demo.fayolex.co.id")
num_users = int(os.environ.get("BENCH_NUM_USERS", "60"))
action = os.environ.get("BENCH_ACTION", "create").lower()

try:
    frappe.init(site=site)
    frappe.connect()
    frappe.flags.in_import = True

    if action == "cleanup":
        # Find all test users
        users = frappe.get_all("User", filters={"email": ["like", "loadtest_%@example.com"]}, pluck="name")
        users += frappe.get_all("User", filters={"email": ["like", "bench_%@example.com"]}, pluck="name")
        users = list(set(users))

        todos_deleted = 0
        for u in users:
            todos = frappe.get_all("ToDo", filters={"owner": u}, pluck="name")
            for name in todos:
                try:
                    frappe.delete_doc("ToDo", name, ignore_permissions=True, force=True)
                    todos_deleted += 1
                except Exception:
                    pass

        users_deleted = 0
        for u in users:
            try:
                frappe.delete_doc("User", u, ignore_permissions=True, force=True)
                users_deleted += 1
            except Exception:
                pass

        frappe.db.commit()
        result = {
            "status": "ok",
            "action": "cleanup",
            "site": site,
            "todos_deleted": todos_deleted,
            "users_deleted": users_deleted
        }
        print(json.dumps(result))

    else:
        # Create pool of distinct test users
        user_list = []
        for i in range(1, num_users + 1):
            email = f"loadtest_{i}@example.com"
            pwd = f"LoadTestPass_{i}!123"

            if not frappe.db.exists("User", email):
                u = frappe.get_doc({
                    "doctype": "User",
                    "email": email,
                    "first_name": f"LoadTester{i}",
                    "enabled": 1,
                    "send_welcome_email": 0,
                    "user_type": "System User",
                    "roles": [{"doctype": "Has Role", "role": "System Manager"}]
                })
                u.insert(ignore_permissions=True)
            else:
                u = frappe.get_doc("User", email)
                u.enabled = 1
                roles = [r.role for r in u.roles]
                if "System Manager" not in roles:
                    u.append("roles", {"doctype": "Has Role", "role": "System Manager"})
                u.save(ignore_permissions=True)

            update_password(user=email, pwd=pwd)
            frappe.set_user("Administrator")
            k = generate_keys(email)
            user_list.append({
                "email": email,
                "password": pwd,
                "api_key": k["api_key"],
                "api_secret": k["api_secret"]
            })

        frappe.db.commit()
        result = {
            "status": "ok",
            "action": "create",
            "site": site,
            "num_users": len(user_list),
            "users": user_list
        }
        print(json.dumps(result))

except Exception as exc:
    err = {
        "status": "error",
        "action": action,
        "site": site,
        "error": str(exc)
    }
    print(json.dumps(err), file=sys.stderr)
    sys.exit(1)
finally:
    try:
        frappe.destroy()
    except Exception:
        pass
