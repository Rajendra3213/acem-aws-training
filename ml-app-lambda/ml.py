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
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', 'arn:aws:sns:us-east-1:454226617526:people-count-topic')

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