## **AWS Deployment Guide: FastAPI on EC2 + RDS PostgreSQL**

### **1. Create RDS PostgreSQL Database**

1. **Go to AWS RDS Console** → Databases → Create database
2. **Engine options**: Select PostgreSQL → Latest version
3. **DB instance class**: `db.t3.micro` (free tier eligible)
4. **Storage**: 20 GB (free tier)
5. **DB instance identifier**: `todo-db`
6. **Master username**: `todouser`
7. **Master password**: `YourSecurePassword123!`
8. **VPC**: Default VPC
9. **Public accessibility**: No (keep private)
10. **Create database**

After creation, note the **Endpoint** (e.g., `todo-db.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com`)

---

### **2. Create Security Group for RDS**

1. Go to **EC2 → Security Groups** → Create security group
2. Name: `rds-postgres-sg`
3. Add inbound rule:
   - Type: PostgreSQL
   - Port: 5432
   - Source: Custom → `0.0.0.0/0` (or restrict to EC2 sg)
4. Create

Attach this security group to your RDS instance.

---

### **3. Launch EC2 Instance**

1. **Go to EC2 → Instances → Launch instance**
2. **AMI**: Ubuntu Server 22.04 LTS (free tier)
3. **Instance type**: `t2.micro` (free tier)
4. **Key pair**: Create or select existing → Download `.pem` file
5. **Security group**: Create new or select existing
   - Inbound: SSH (22) from your IP
   - Inbound: HTTP (80) from `0.0.0.0/0`
   - Inbound: HTTPS (443) from `0.0.0.0/0`
   - Inbound: Custom TCP 8000 from `0.0.0.0/0` (for Uvicorn)
6. **Storage**: 20 GB (default)
7. **Launch**

Note the **Public IPv4 address** (e.g., `54.123.45.67`)

---

### **4. Connect to EC2 and Install Dependencies**

```bash
# SSH into EC2
ssh -i your-key.pem ubuntu@54.123.45.67

# Update system
sudo apt update && sudo apt upgrade -y

# Install Python and pip
sudo apt install -y python3 python3-pip python3-venv

# Install git
sudo apt install -y git

# Install postgresql client (optional, for testing DB connection)
sudo apt install -y postgresql-client

# Clone your repository
git clone https://github.com/your-repo/PythonWebApp.git
cd PythonWebApp

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

---

### **5. Set Environment Variables**

Create a `.env` file in the project root:

```bash
cat > .env <<'EOF'
DATABASE_URL=postgresql://todouser:YourSecurePassword123!@todo-db.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com:5432/todo_db
EOF
```

Replace:
- `todouser` → your RDS master username
- `YourSecurePassword123!` → your RDS master password
- `todo-db.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com` → your RDS endpoint

---

### **6. Create Database in RDS**

```bash
# Test connection to RDS
psql -h todo-db.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com -U todouser -d postgres

# At psql prompt, create the todo_db database
CREATE DATABASE todo_db;
\q
```

---

### **7. Run Application (Development)**

```bash
# Activate venv
source venv/bin/activate

# Load environment variables
export $(cat .env | xargs)

# Run uvicorn
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Access at: `http://54.123.45.67:8000/`

---

### **8. Production Setup (Recommended)**

#### **A. Use Systemd for Auto-restart**

Create `/etc/systemd/system/todoapp.service`:

```bash
sudo cat > /etc/systemd/system/todoapp.service <<'EOF'
[Unit]
Description=Todo FastAPI Application
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/PythonWebApp
Environment="PATH=/home/ubuntu/PythonWebApp/venv/bin"
EnvironmentFile=/home/ubuntu/PythonWebApp/.env
ExecStart=/home/ubuntu/PythonWebApp/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable todoapp
sudo systemctl start todoapp
sudo systemctl status todoapp
```

#### **B. Install Nginx as Reverse Proxy**

```bash
sudo apt install -y nginx

# Create nginx config
sudo cat > /etc/nginx/sites-available/todo <<'EOF'
server {
    listen 80;
    server_name 54.123.45.67;  # or your domain

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Serve OpenAPI docs
    location /.well-known {
        proxy_pass http://127.0.0.1:8000;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/todo /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

Now access: `http://54.123.45.67/` (port 80, nginx forwards to 8000)

---

### **9. Configure Health Check (Optional)**

In **EC2 → Load Balancers** (if using ALB):
- Target group health check: `GET /.well-known/health`
- Expected response: `200`

---

### **10. Test Everything**

```bash
# SSH into EC2
ssh -i your-key.pem ubuntu@54.123.45.67

# Check service status
sudo systemctl status todoapp

# Check logs
sudo journalctl -u todoapp -f

# Test health endpoint
curl http://localhost:8000/.well-known/health

# Test DB connection
curl http://localhost:8000/.well-known/swagger.json
```

---

### **Quick Reference: Useful Commands**

```bash
# View logs
sudo journalctl -u todoapp -n 50

# Restart application
sudo systemctl restart todoapp

# Stop application
sudo systemctl stop todoapp

# Check if port 8000 is listening
sudo netstat -tuln | grep 8000

# View nginx errors
sudo tail -f /var/log/nginx/error.log

# Reload nginx config
sudo nginx -s reload
```

---

### **Cost Estimate (Free Tier)**

- **EC2**: t2.micro free for 12 months
- **RDS**: db.t3.micro free tier (750 hours/month)
- **Total**: $0 (first year, if within free tier limits)

---

That's it! Your FastAPI app is now running on AWS with RDS PostgreSQL.