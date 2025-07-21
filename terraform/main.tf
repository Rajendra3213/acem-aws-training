# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_access_key" {
  description = "AWS access key ID"
  type        = string
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS secret access key"
  type        = string
  sensitive   = true
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "bucket_name" {
  description = "S3 bucket name for storing photos"
  type        = string
  default     = "email-photo-bucket"
}

variable "notification_email" {
  description = "Email address for SNS notifications"
  type        = string
}

variable "owner_email" {
  description = "Owner email for resource tagging"
  type        = string
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 30
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# S3 Bucket for storing photos
resource "aws_s3_bucket" "photo_bucket" {
  bucket = var.bucket_name

  tags = {
    Name        = "People Counter Photo Bucket"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "photo_bucket_pab" {
  bucket = aws_s3_bucket.photo_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "photo_bucket_versioning" {
  bucket = aws_s3_bucket.photo_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SNS Topic for notifications
resource "aws_sns_topic" "people_count_topic" {
  name = "people-count-topic"

  tags = {
    Name        = "People Count Notifications"
    Environment = var.environment
  }
}

# SNS Topic Subscription (Email)
resource "aws_sns_topic_subscription" "email_notification" {
  topic_arn = aws_sns_topic.people_count_topic.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_execution_role" {
  name = "people-counter-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "People Counter Lambda Role"
    Environment = var.environment
  }
}

# IAM Policy for Lambda
resource "aws_iam_policy" "lambda_policy" {
  name        = "people-counter-lambda-policy"
  description = "IAM policy for people counter Lambda function"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3ReadAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.photo_bucket.arn}/*"
      },
      {
        Sid    = "AllowRekognitionDetect"
        Effect = "Allow"
        Action = [
          "rekognition:DetectLabels"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSNSPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.people_count_topic.arn
      },
      {
        Sid    = "AllowBasicLambdaExecution"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  policy_arn = aws_iam_policy.lambda_policy.arn
  role       = aws_iam_role.lambda_execution_role.name
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/people-counter-function"
  retention_in_days = 14

  tags = {
    Environment = var.environment
  }
}

# Lambda function code archive
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"
  
  source {
    content = <<EOF
import boto3
import logging
import json
import os

# Initialize logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

rekognition = boto3.client('rekognition')
sns = boto3.client('sns')

# Get SNS topic ARN from environment variable
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN')

def lambda_handler(event, context):
    try:
        logger.info("Event received: %s", json.dumps(event))
        
        # Handle both S3 event and direct invocation
        if 'Records' in event and event['Records']:
            # S3 event trigger
            record = event['Records'][0]
            bucket = record['s3']['bucket']['name']
            key = record['s3']['object']['key']
        else:
            # Direct invocation - expect bucket and key in event
            bucket = event.get('bucket')
            key = event.get('key')
            if not bucket or not key:
                raise ValueError("bucket and key must be provided in the event")
        
        logger.info(f"Processing image from bucket: {bucket}, key: {key}")
        
        # URL decode the key in case it has special characters
        from urllib.parse import unquote_plus
        key = unquote_plus(key)
        
        # Call Rekognition to detect labels
        response = rekognition.detect_labels(
            Image={'S3Object': {'Bucket': bucket, 'Name': key}},
            MaxLabels=10,
            MinConfidence=70
        )
        
        logger.info("Rekognition response received")
        
        person_count = 0
        people_detected = False
        
        for label in response['Labels']:
            logger.info(f"Detected label: {label['Name']} with confidence: {label['Confidence']:.2f}%")
            
            if label['Name'].lower() == 'person':
                people_detected = True
                # Count instances if available, otherwise count as 1
                instances = label.get('Instances', [])
                if instances:
                    person_count = len(instances)
                    logger.info(f"Found {person_count} person instances")
                else:
                    # If no instances but person label exists, assume at least 1
                    person_count = 1
                    logger.info("Person label found but no instances - assuming 1 person")
                break
        
        if not people_detected:
            logger.info("No people detected in the image")
        
        logger.info(f"Total number of people detected: {person_count}")
        
        # Create message
        message = {
            "bucket": bucket,
            "key": key,
            "people_count": person_count,
            "timestamp": context.aws_request_id,
            "all_labels": [{"name": label['Name'], "confidence": label['Confidence']} 
                          for label in response['Labels']]
        }
        
        # Publish to SNS
        sns_response = sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"People Count Analysis: {person_count} people detected",
            Message=json.dumps(message, indent=2)
        )
        
        logger.info(f"SNS publish response: {json.dumps(sns_response, default=str)}")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': f'Successfully processed image. Found {person_count} people.',
                'people_count': person_count,
                'bucket': bucket,
                'key': key
            })
        }
        
    except Exception as e:
        error_msg = f"Error processing image: {str(e)}"
        logger.error(error_msg, exc_info=True)
        
        # Try to send error notification to SNS
        try:
            if SNS_TOPIC_ARN:
                sns.publish(
                    TopicArn=SNS_TOPIC_ARN,
                    Subject="Error in People Count Analysis",
                    Message=f"Failed to process image: {error_msg}"
                )
        except Exception as sns_error:
            logger.error(f"Failed to send error notification to SNS: {str(sns_error)}")
        
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': 'Failed to process image',
                'message': error_msg
            })
        }
EOF
    filename = "lambda_function.py"
  }
}

# Lambda Function
resource "aws_lambda_function" "people_counter" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "people-counter-function"
  role            = aws_iam_role.lambda_execution_role.arn
  handler         = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime         = "python3.9"
  timeout         = var.lambda_timeout
  memory_size     = 256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.people_count_topic.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_policy_attachment,
    aws_cloudwatch_log_group.lambda_logs,
  ]

  tags = {
    Name        = "People Counter Function"
    Environment = var.environment
  }
}

# Lambda permission for S3 to invoke the function
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.people_counter.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.photo_bucket.arn
}

# S3 bucket notification to trigger Lambda
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.photo_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.people_counter.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = ""
    filter_suffix       = ""
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

# Outputs
output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.photo_bucket.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.photo_bucket.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.people_counter.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.people_counter.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic"
  value       = aws_sns_topic.people_count_topic.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group for Lambda"
  value       = aws_cloudwatch_log_group.lambda_logs.name
}

# output "test_upload_command" {
#   description = "AWS CLI command to test by uploading a photo"
#   value       = "aws s3 cp your-photo.jpg s3://${aws_s3_bucket.photo_bucket.bucket}/"
# }