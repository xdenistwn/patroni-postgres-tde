1. Download mc client
```
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
./mc --help
```

2. Set Alias (connect to minio)
command: mc alias set myminio https://localhost:9000 minioadmin minioadmin --insecure
result: 
Added `myminio` successfully.

3. Create bucket
command: mc mb myminio/postgres-archive-dev-cluster-1 --insecure
result: 
Bucket `myminio/postgres-archive-dev-cluster-1` created successfully.

4. List bucket
command: mc ls myminio --insecure
result: 
[2026-03-08 05:14:15 UTC]      0B postgres-archive-dev-cluster-1/

5. Set bucket to private (default, but explicit)
command: mc anonymous set none myminio/postgres-archive-dev-cluster-1 --insecure
result: 
Access permission for `myminio/postgres-archive-dev-cluster-1` is set to `private`

6. Create a user for pgbackrest
command: mc admin user add myminio pgbackrest-dev strong-password-123 --insecure
result: 
User `pgbackrest-dev` created successfully.

7. Create a policy for pgbackrest using aws aim format
cat > pgbackrest-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::postgres-archive-dev-cluster-1"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::postgres-archive-dev-cluster-1/*"
      ]
    }
  ]
}
EOF

8. Add the policy
command: mc admin policy create myminio pgbackrest-policy pgbackrest-policy.json --insecure
result: 
Policy `pgbackrest-policy` created successfully.

9. Attach the policy to the user
command: mc admin policy attach myminio pgbackrest-policy --user=pgbackrest-dev --insecure
result: 
Attached Policies: [pgbackrest-policy]
To User: pgbackrest-dev

10. Verify the policy
command: mc admin user list myminio --insecure
result: 
enabled    pgbackrest-dev            pgbackrest-policy