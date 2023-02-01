# Data Engineering Melbourne - January 2023

### Purpose
Demonstrate schema validation with a dead-letter-topic.

### Context
This repo supports a demo for Data Engineering Melbourne meetup group.
Presented 2nd Feb 2023

### Process
1. Setup infra in Confluent Cloud using Terraform
2. Generate API key - SR RBAC not supported in Terraform yet
3. Generate data `python3 producer.py`
4. Set schema rules via UI, note the schema ID
5. Use KSQL
6. Inspect Processing Log

