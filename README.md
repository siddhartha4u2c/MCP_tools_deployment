# MCP from scratch → deployed on AWS

## 1. What MCP is (in 60 seconds)

**Model Context Protocol (MCP)** is a standard way for an AI app to use outside capabilities.
Instead of writing custom glue for every tool, you write an **MCP server** once and any
**MCP client** (Claude Desktop, Claude Code, Cursor, your own app) can use it.

```
 AI app (host)  ──contains──>  MCP client  ──JSON-RPC over a transport──>  MCP server
 e.g. Claude Desktop            (client.py)        stdio  or  HTTP            (server.py)
```

A server offers three kinds of things:

| Primitive | What it is | In `server.py` |
|-----------|-----------|----------------|
| **Tool** | A function the model can *call* (it acts / computes) | `add`, `word_count`, `utc_now` |
| **Resource** | Data the model can *read* (like a file) | `notes://welcome` |
| **Prompt** | A reusable prompt template | `summarize` |

Two transports:
- **stdio**: the client starts the server as a local subprocess. Good for desktop use. Nothing to deploy.
- **Streamable HTTP**: the server is a web service at `/mcp`. This is what you deploy to the cloud.

Every session starts with a handshake (`initialize`), then the client can `list_tools`,
`call_tool`, `read_resource`, `get_prompt`.

## 2. Files

```
server.py          the MCP server (tools, resource, prompt, /health, API-key check)
client.py          a client that connects and calls everything once
requirements.txt   pinned dependencies
Dockerfile         container image for AWS
deploy/deploy.sh   one-shot AWS deployment (ECR + ECS Fargate)
deploy/teardown.sh deletes every AWS resource the deploy created
```

> Don't name any file `mcp.py` next to these scripts. Python would import it instead of the real
> `mcp` library.

## 3. Run it locally

```bash
pip install -r requirements.txt

# Terminal 1: start the server (no API key set = no auth locally)
python server.py

# Terminal 2: run the client
python client.py
```

Expected output:
```
Tools: ['add', 'word_count', 'utc_now']
add(2, 3) -> 5.0
word_count -> {"words": 4, "characters": 28}
...
```

**Try it with Claude Desktop (stdio).** Add this to `%APPDATA%\Claude\claude_desktop_config.json`, then restart Claude Desktop and ask it "what is 17.5 + 4?":
```json
{
  "mcpServers": {
    "demo": {
      "command": "python",
      "args": ["C:\\Users\\HP\\Downloads\\MCP\\mcp-demo\\server.py", "--stdio"]
    }
  }
}
```

**Inspect it visually:** `npx @modelcontextprotocol/inspector` opens a web UI. Choose
"Streamable HTTP", enter `http://localhost:8000/mcp`, and click tools to call them.

## 4. Deploy to AWS

### The architecture
```
your laptop ── docker push ──> ECR (image registry)
                                    │ pulls image
client.py ── HTTP :8000 ──> ECS Fargate task (your container, public IP)
                                    │ secret: MCP_API_KEY       │ logs
                              SSM Parameter Store         CloudWatch Logs
```

| AWS service | Why it's needed |
|-------------|-----------------|
| **ECR** | Stores your Docker image |
| **ECS Fargate** | Runs the container without you managing a server |
| **IAM role** | Gives ECS permission to pull the image, write logs and read the secret |
| **SSM Parameter Store** | Holds the API key encrypted, so it's never baked into the image |
| **Security group** | Firewall: only *your* IP can reach port 8000 |
| **CloudWatch Logs** | Where `print`/uvicorn output goes |

### Steps
1. Start **Docker Desktop**.
2. Check the AWS CLI works: `aws sts get-caller-identity`
3. From this folder in **Git Bash**: `bash deploy/deploy.sh`
4. At the end it prints the public IP. Test it:
   ```bash
   curl http://<IP>:8000/health
   export MCP_API_KEY=$(aws ssm get-parameter --name /mcp-demo/api-key --with-decryption --query Parameter.Value --output text)
   python client.py http://<IP>:8000/mcp
   ```
5. Without the key you'll get `401 unauthorized`, which shows the protection is working.

Read `deploy/deploy.sh` top to bottom. Each numbered block is one AWS concept, and the
script is safe to re-run (it updates instead of duplicating).

**Updating the code:** edit `server.py`, run `bash deploy/deploy.sh` again. It pushes a new
image and rolls the service. The public IP changes on each redeploy.

**Viewing logs:** `aws logs tail /ecs/mcp-demo --follow`

### Cost
One Fargate task at 0.25 vCPU / 0.5 GB costs about **$0.01 per hour (~$9/month)** in us-east-1,
plus a few cents for ECR storage and a small public IPv4 charge. **Run `bash deploy/teardown.sh` when you're done.**

## 5. Going to production (next steps)

This setup is deliberately minimal. For a real deployment, add:
- An **Application Load Balancer + ACM certificate** so you get HTTPS and a stable domain name
  instead of plain HTTP on a changing IP. Never send API keys over plain HTTP on the open internet.
- **OAuth** (the MCP spec's auth standard) instead of a shared API key, if many users connect.
- `desired-count 2+` across availability zones. The server is `stateless_http=True`, so it scales out.
- Infrastructure as code (AWS CDK / Terraform) instead of a shell script.
- Connecting Claude to the remote server: in Claude Code, `claude mcp add --transport http demo https://<your-domain>/mcp --header "Authorization: Bearer <key>"`.
