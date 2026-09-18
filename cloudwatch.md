# CloudWatch Logs, from zero

A beginner's guide to what CloudWatch Logs is and how this Todo API uses it.
No prior CloudWatch knowledge assumed. Every command here was run against this
app's real log group; the sample output is copied from those runs.

Related: [deployment.md](deployment.md) for deploying, [README.md](README.md)
for running locally.

---

## 1. The problem it solves

When the app runs on your laptop, log lines go to your terminal:

```
INFO:todo_api:started request path=/todos method=GET
INFO:todo_api:completed request path=/todos status=200 duration=0.004s
```

On an EC2 server there is no terminal to watch. The logs go to the systemd
journal instead, and you read them by SSH-ing in:

```bash
sudo journalctl -u todoapp -f
```

That works, but it has real limits:

- **The logs die with the server.** Terminate the instance and they're gone —
  including the logs explaining why you had to terminate it.
- **You have to SSH in** to read anything, which means holding a key to
  production just to answer "did that request 500?"
- **One server at a time.** With three instances behind a load balancer,
  "find that error" means SSH-ing into three boxes and grepping each.

CloudWatch Logs is AWS's answer: your app ships log lines to a service that
stores, searches, and retains them independently of the server. The instance can
be terminated and the logs remain.

---

## 2. The four words you need

CloudWatch Logs has a small vocabulary. Mapped onto this app:

| Term | What it is | In this app |
|---|---|---|
| **Log event** | A single line, plus a timestamp | `completed request path=/todos status=200 duration=0.004s` |
| **Log stream** | An ordered sequence of events from *one source* | One per app process — a new one each restart |
| **Log group** | A named collection of streams, where settings live | `todo-api-logs` |
| **Retention** | How long the group keeps events | Default: **forever** (see §7) |

The nesting is just: **group → streams → events**.

A real stream name from this deployment:

```
ip-172-31-1-225//home/ubuntu/TodoPythonApp/venv/bin/uvicorn/todo_api/5901
```

That's the library's default naming: hostname, program path, logger name, and
process ID. Ugly, but it tells you exactly which process produced a line. Restart
the service and you get a new stream — same group, new PID. After two restarts
this deployment had two streams:

```
ip-172-31-1-225/.../todo_api/5901
ip-172-31-1-225/.../todo_api/6977
```

Settings like retention and access are configured **per group**, never per
stream. That's the main reason the distinction matters.

---

## 3. How this app ships logs

Three pieces have to line up. If any one is missing, logging silently falls back
to stdout only — the app never crashes over it.

```
Python logging  ──▶  watchtower handler  ──▶  boto3  ──▶  CloudWatch Logs
   (your code)         (batches lines)      (signs the       (todo-api-logs)
                                             API calls)
```

**1. The handler**, attached at startup in [app/main.py](app/main.py#L21-L56).
`logging` is Python's built-in logging module; a *handler* is a plug-in that
decides where log lines go. [watchtower](https://pypi.org/project/watchtower/) is
a handler that sends them to CloudWatch:

```python
cw_handler = watchtower.CloudWatchLogHandler(
    log_group_name=log_group,
    boto3_client=boto3.client("logs", region_name=region),
)
logger.addHandler(cw_handler)
```

**2. A region**, read from `AWS_REGION`, falling back to `AWS_DEFAULT_REGION`.
CloudWatch is regional — `todo-api-logs` in `us-east-1` is a different group from
the same name in `eu-west-1`. If neither variable is set the app still tries,
letting boto3 discover the region from instance metadata or `~/.aws/config`;
supplying it explicitly just turns a confusing failure into a clear one.

**3. Permission to write.** The EC2 instance carries an IAM role granting:

```
logs:CreateLogGroup      logs:CreateLogStream      logs:PutLogEvents
logs:DescribeLogGroups   logs:DescribeLogStreams
```

The first three are what watchtower needs to ship logs; the two `Describe`
actions let you list groups and streams from the instance itself.

An *IAM role* on an instance is credentials AWS injects automatically, so you
never put access keys on the server. `boto3` finds them without configuration —
you can see it happen in the startup log:

```
INFO:botocore.credentials:Found credentials from IAM Role: todo-ec2-cloudwatch-role
```

All three are set up by [deployment.md](deployment.md) steps 3 and 8, or
automatically by [deploy/](deploy/README.md).

The group name is configurable via `CLOUDWATCH_LOG_GROUP` and defaults to
`todo-api-logs`. **You don't have to create the group by hand** — the handler
creates it on first use, which is why `logs:CreateLogGroup` is in the policy.

---

## 4. Reading your logs

### In the console

CloudWatch → **Log groups** → `todo-api-logs` → pick a stream. Check the region
selector in the top-right first; the wrong region shows an empty list and looks
identical to "logging is broken."

**Live tail** follows new events as they arrive. It's the closest thing to
`journalctl -f`, and it bills separately from storage.

### From the CLI

`aws logs tail` is the friendliest command:

```bash
aws logs tail todo-api-logs --since 10m --format short
```

Real output from this deployment:

```
2026-09-18T07:53:48 started request path=/todos method=GET
2026-09-18T07:53:48 completed request path=/todos status=200 duration=0.004s
2026-09-18T07:53:48 started request path=/todos/99999999 method=GET
2026-09-18T07:53:48 completed request path=/todos/99999999 status=404 duration=0.005s
2026-09-18T07:53:48 started request path=/todos method=POST
2026-09-18T07:53:48 completed request path=/todos status=200 duration=0.010s
```

Add `--follow` to stream new events as they arrive.

Other useful commands:

```bash
# Which groups exist?
aws logs describe-log-groups --query 'logGroups[].logGroupName'

# Which streams, newest first?
aws logs describe-log-streams --log-group-name todo-api-logs \
  --order-by LastEventTime --descending \
  --query 'logStreams[].logStreamName'
```

---

## 5. Searching

### filter-log-events

Plain substring-ish search across every stream in a group:

```bash
# note --start-time: see the gotcha below
aws logs filter-log-events --log-group-name todo-api-logs \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) \
  --filter-pattern '"status=404"' \
  --query 'events[].message' --output text
```

Measured counts over the same one-hour window on this deployment:

| `--filter-pattern` | Events |
|---|---|
| *(none)* | 128 |
| `"status=200"` | 57 |
| `"status=404"` | 7 |
| `"method=POST"` | 5 |
| `nonexistentxyz` | 0 |

Two things that will waste your afternoon:

> **`--start-time` is effectively mandatory.** Omitting it returned **0 events**
> in testing, even with events plainly present and no pattern set. It looks
> exactly like "my logging is broken." The value is **milliseconds** since the
> epoch, not seconds — hence the `* 1000`.

> **Quote patterns containing `=`, `:`, or spaces.** `'"status=404"'` (double
> quotes inside single quotes) matches; a bare `status=404` does not.

### Logs Insights

For anything analytical, use Logs Insights — a small query language with its own
console page. Counting requests by status:

```
fields @timestamp, @message
| filter @message like /status=/
| parse @message "status=* " as status
| stats count(*) by status
```

Finding the slowest requests:

```
fields @timestamp, @message
| parse @message "duration=*s" as duration
| sort duration desc
| limit 20
```

From the CLI it's two calls, because queries run asynchronously:

```bash
QID=$(aws logs start-query --log-group-name todo-api-logs \
  --start-time $(( $(date +%s) - 3600 )) --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | filter @message like /status=404/ | sort @timestamp desc | limit 3' \
  --query queryId --output text)

sleep 5   # poll until status is Complete
aws logs get-query-results --query-id "$QID"
```

Verified output:

```
status: Complete
  2026-09-18 07:53:48.715 | completed request path=/todos/99999999 status=404 duration=0.005s
  2026-09-18 07:53:48.688 | completed request path=/todos/99999999 status=404 duration=0.006s
  2026-09-18 07:53:48.657 | completed request path=/todos/99999999 status=404 duration=0.005s
```

Note the `--start-time` here is in **seconds**, unlike `filter-log-events`.
Yes, that inconsistency is real.

Insights reports what it scanned, which is what you're billed on:

```json
{"recordsMatched": 64.0, "recordsScanned": 128.0, "bytesScanned": 10615.0}
```

Narrower time ranges scan less and cost less.

---

## 6. Why your logs aren't there yet

**This is the single most common "it's broken" moment, and it usually isn't.**

watchtower **batches** events and flushes roughly once a minute rather than making
an API call per log line. So right after startup you will typically see the log
group exist with **zero streams and zero events**. That's expected.

The sequence is:

1. App starts → handler initialises → **group created immediately** (empty)
2. Requests arrive → lines queue in memory
3. ~60s later → first flush → stream appears, events become searchable

So: **the group existing proves permissions and region are correct.** Events
showing up proves the flush happened. If the group exists, you're already fine —
wait a minute.

`storedBytes` is also not a liveness signal. This group reported `0` while
`aws logs tail` was returning events normally; the field lags.

One consequence worth knowing: because events are buffered in memory, a hard
crash can lose the last few seconds of logs. For an app whose final log line
matters, the journal on the instance is the more reliable copy —
CloudWatch complements `journalctl`, it doesn't replace it.

---

## 7. Retention and cost

By default, **log groups keep events forever** and you pay storage forever. This
group was created by watchtower, so it started out that way:

```bash
aws logs describe-log-groups --log-group-name-prefix todo-api-logs \
  --query 'logGroups[0].{Name:logGroupName,Retention:retentionInDays,Stored:storedBytes}'
```

```json
{"Name": "todo-api-logs", "Retention": null, "Stored": 0}
```

`null` means never expire. For a test deployment, set something finite:

```bash
aws logs put-retention-policy --log-group-name todo-api-logs --retention-in-days 7
```

After that, the describe command reports `"Retention": 7` instead of `null`.
Lowering retention deletes events already older than the new limit, so check the
age of what's in the group before shortening it on anything you care about.

Better still, create the group in code so retention is set before the first log
line rather than remembered afterwards — [terraform/irsa.tf](terraform/irsa.tf)
declares it with `retention_in_days`, so watchtower finds it already configured.

Retention accepts only a fixed set of values, not any integer — asking for 8 days
fails and leaves the existing setting untouched:

```
InvalidParameterException ... Invalid retention value. Valid values are:
[1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827,
 2192, 2557, 2922, 3288, 3653]
```

Rough pricing (us-east-1, verify against current AWS pricing):

| What you pay for | Approximate rate |
|---|---|
| Ingestion | ~$0.50 per GB |
| Storage | ~$0.03 per GB-month |
| Insights queries | ~$0.005 per GB scanned |
| Free tier | 5 GB ingestion + 5 GB storage per month |

This app's request logging is tiny — the whole test run above was ~10 KB. Costs
become real when a chatty app logs every request at scale, or when a stack trace
loop runs unattended. Two habits that prevent surprise bills: set retention on
every group, and don't log at `DEBUG` in production.

Deleting a group deletes its events, permanently:

```bash
aws logs delete-log-group --log-group-name todo-api-logs
```

`deploy/teardown.sh` does this for you.

---

## 8. Troubleshooting

**Log group exists but is empty** — almost always §6. Wait ~60s and re-check.

**`unexpected keyword argument 'region_name'`**

```
CloudWatch handler unavailable: Handler.__init__() got an unexpected keyword argument 'region_name'
```

watchtower 3.x removed `region_name`; you pass a configured `boto3_client`
instead. Fixed in [app/main.py](app/main.py#L30-L42), and `requirements.txt`
pins `watchtower>=3.0.0`. **Setting `AWS_REGION` does not help** — despite the
warning text saying so, the region is not the problem. If you see this, your code
or your watchtower version is old.

**`You must specify a region`** — this one *is* a missing region. Set
`AWS_DEFAULT_REGION` (or `AWS_REGION`) in `.env` and restart the service.

**`AccessDeniedException` on `CreateLogGroup` or `PutLogEvents`** — the instance
role lacks permissions. Confirm the role is attached and has the `logs:` actions
from §3:

```bash
aws sts get-caller-identity     # run on the instance: should show the role
```

**Nothing in the console, but the CLI shows events** — you're looking at the
wrong region. Check the region selector.

**No warning, no events, group never created** — the handler probably never
attached. Check startup logs for the `watchtower` import:

```bash
sudo journalctl -u todoapp -n 50 --no-pager | grep -i -e cloudwatch -e watchtower
```

Silence there means `watchtower` isn't installed in the venv — the import is
wrapped in `try/except ImportError` precisely so the app still runs locally
without it.

---

## 9. Try it yourself

With the app deployed ([deployment.md](deployment.md)):

```bash
# 1. Generate some traffic (on the instance)
curl -s -o /dev/null http://localhost/todos
curl -s -o /dev/null http://localhost/todos/99999999    # a 404 to search for

# 2. Confirm the group exists -- proves region + permissions
aws logs describe-log-groups --log-group-name-prefix todo-api-logs \
  --query 'logGroups[].logGroupName'

# 3. Wait for the flush, then read the events
sleep 65
aws logs tail todo-api-logs --since 5m --format short

# 4. Search for just the 404s
aws logs filter-log-events --log-group-name todo-api-logs \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) \
  --filter-pattern '"status=404"' \
  --query 'events[].message' --output text

# 5. Stop paying to store this forever
aws logs put-retention-policy --log-group-name todo-api-logs --retention-in-days 7
```

Step 3 is where beginners give up too early. If step 2 printed the group name,
the plumbing works — the events are coming.
