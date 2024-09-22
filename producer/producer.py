import pika
import sys
import time

def publish_message():
    connection = pika.BlockingConnection(pika.ConnectionParameters('rabbitmq'))
    channel = connection.channel()

    channel.queue_declare(queue='input_queue')

    while True:
        message = "Hello from Producer!"
        channel.basic_publish(exchange='', routing_key='input_queue', body=message)
        print(f" [x] Sent '{message}'")
        time.sleep(2)

if __name__ == '__main__':
    publish_message()
