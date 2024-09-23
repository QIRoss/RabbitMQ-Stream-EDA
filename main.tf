provider "aws" {
  region  = "us-east-1"
  profile = "qiross"
}

resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "main_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

resource "aws_security_group" "instance_sg" {
  vpc_id = aws_vpc.main_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  ingress {
    from_port   = 15672
    to_port     = 15672
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create IAM role for SSM
resource "aws_iam_role" "ssm_role" {
  name = "EC2SSMRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach the SSM managed policy to the role
resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an instance profile for the EC2 instances
resource "aws_iam_instance_profile" "ssm_instance_profile" {
  name = "EC2SSMInstanceProfile"
  role = aws_iam_role.ssm_role.name
}

# RabbitMQ instance with SSM role
resource "aws_instance" "rabbitmq" {
  ami                         = "ami-0c02fb55956c7d316"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.main_subnet.id
  vpc_security_group_ids      = [aws_security_group.instance_sg.id]
  key_name                    = "qiross"
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm_instance_profile.name

  tags = {
    Name = "rabbitmq-instance"
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y docker
    sudo service docker start
    sudo docker run -d --network host --name rabbitmq rabbitmq:3-management
  EOF
}

# Producer instance with SSM role
resource "aws_instance" "producer" {
  ami                         = "ami-0c02fb55956c7d316"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.main_subnet.id
  vpc_security_group_ids      = [aws_security_group.instance_sg.id]
  key_name                    = "qiross"
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm_instance_profile.name

  tags = {
    Name = "producer-instance"
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y docker
    sudo service docker start

    # Create producer directory
    mkdir -p /home/ec2-user/producer

    # Create producer files
    cat << 'PRODUCER_DOCKERFILE' > /home/ec2-user/producer/Dockerfile
    FROM python:3.9-slim
    WORKDIR /app
    COPY ./requirements.txt /app/requirements.txt
    RUN pip install --no-cache-dir -r requirements.txt
    COPY . /app
    CMD ["python", "producer.py"]
    PRODUCER_DOCKERFILE

    cat << 'PRODUCER_SCRIPT' > /home/ec2-user/producer/producer.py
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
    PRODUCER_SCRIPT

    cat << 'PRODUCER_REQUIREMENTS' > /home/ec2-user/producer/requirements.txt
    pika
    streamz
    PRODUCER_REQUIREMENTS

    # Build and run producer container
    cd /home/ec2-user/producer
    sudo docker build -t producer .
    sudo docker run -d --network host --name producer producer
  EOF
}

# Consumer instance with SSM role
resource "aws_instance" "consumer" {
  ami                         = "ami-0c02fb55956c7d316"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.main_subnet.id
  vpc_security_group_ids      = [aws_security_group.instance_sg.id]
  key_name                    = "qiross"
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm_instance_profile.name

  tags = {
    Name = "consumer-instance"
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y docker
    sudo service docker start

    # Create consumer directory
    mkdir -p /home/ec2-user/consumer

    # Create consumer files
    cat << 'CONSUMER_DOCKERFILE' > /home/ec2-user/consumer/Dockerfile
    FROM python:3.9-slim
    WORKDIR /app
    COPY ./requirements.txt /app/requirements.txt
    RUN pip install --no-cache-dir -r requirements.txt
    COPY . /app
    CMD ["python", "consumer.py"]
    CONSUMER_DOCKERFILE

    cat << 'CONSUMER_SCRIPT' > /home/ec2-user/consumer/consumer.py
    import pika
    from streamz import Stream

    def callback(ch, method, properties, body):
        stream.emit(body.decode())

    def consume_message():
        connection = pika.BlockingConnection(pika.ConnectionParameters('rabbitmq'))
        channel = connection.channel()

        channel.queue_declare(queue='input_queue')

        channel.basic_consume(queue='input_queue', on_message_callback=callback, auto_ack=True)
        print(' [*] Waiting for messages. To exit press CTRL+C')
        channel.start_consuming()

    stream = Stream()

    stream.map(lambda message: message.upper()).sink(lambda msg: print(f"Processed message: {msg}"))

    if __name__ == '__main__':
        consume_message()
    CONSUMER_SCRIPT

    cat << 'CONSUMER_REQUIREMENTS' > /home/ec2-user/consumer/requirements.txt
    pika
    streamz
    CONSUMER_REQUIREMENTS

    # Build and run consumer container
    cd /home/ec2-user/consumer
    sudo docker build -t consumer .
    sudo docker run -d --network host --name consumer consumer
  EOF
}
