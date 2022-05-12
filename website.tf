provider "aws" {
    region = "us-east-1"    
    access_key = "AKIAYMTN3PCU22QNCXIJ"
    secret_key = "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"
    //version = "= 2.17.0"
}

/*terraform {
      required_providers {
         aws = {
         source = "hashicorp/aws"
         version = "= 3.74.2"
        }
     }
  }
*/



resource "aws_vpc" "my_website_vpc" {
  cidr_block = "10.16.0.0/16"
  tags = {
    "Name" = "my_website_vpc"
  }
  assign_generated_ipv6_cidr_block = true 
  enable_dns_hostnames=true
}

resource "aws_subnet" "website_subnet" {
  tags = {
        Name = "website_subnet"
    }
    vpc_id = aws_vpc.my_website_vpc.id
    cidr_block = "10.16.0.0/20"
    map_public_ip_on_launch = true
    depends_on= [aws_vpc.my_website_vpc]

}

resource "aws_route_table" "website_rt" {
  vpc_id = aws_vpc.my_website_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.website_igw.id
  }

  tags = {
    Name = "website_rt"
  }
}

resource "aws_route_table_association" "website_rt_association" {
  subnet_id = aws_subnet.website_subnet.id 
  route_table_id = aws_route_table.website_rt.id
}

resource "aws_internet_gateway" "website_igw" {
  vpc_id = aws_vpc.my_website_vpc.id

  tags = {
    Name = "website_igw"
  }
}

resource "aws_security_group" "website_sg" {
  name = "website_sg"
  description = "Allow web inbound traffic"
  vpc_id = aws_vpc.my_website_vpc.id 
  ingress {
    description      = "http traffic"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }
 
  tags = {
    Name = "website_sg"
  }
}

resource "tls_private_key" "web-key" {
  algorithm = "RSA"
}

resource "aws_key_pair" "web-instance-key" {
  key_name = "web-key"
  public_key = tls_private_key.web-key.public_key_openssh 
}

resource "local_file" "web-key" {
  content = tls_private_key.web-key.private_key_pem
  filename = "web-key.pem"
}

resource "aws_instance" "web-instance" {
  ami = "ami-0022f774911c1d690"
  instance_type = "t2.micro"
  tags = {
    "Name" = "WebServer"
  }
  count = 1 
  subnet_id = aws_subnet.website_subnet.id
  key_name = "web-key"
  security_groups = [aws_security_group.website_sg.id]

  provisioner "remote-exec" {
  connection {
      type = "ssh"
      user = "ec2-user"
      agent = true 
      private_key = tls_private_key.web-key.private_key_pem
      host = aws_instance.web-instance[0].public_ip
  }
  inline = [
        "sudo yum install httpd  php git -y",
        "sudo systemctl restart httpd",
        "sudo systemctl enable httpd",
  ]
  }
} 

resource "aws_ebs_volume" "website_ebs" {
  availability_zone = aws_instance.web-instance[0].availability_zone
  size = 1
  tags = {
    "Name" = "website_ebs"
  }
}

resource "aws_volume_attachment" "attatch_ebs" {
  depends_on = [aws_ebs_volume.website_ebs]
  device_name = "/dev/sdh"
  volume_id = aws_ebs_volume.website_ebs.id
  instance_id = aws_instance.web-instance[0].id 
  force_detach = true 
}

resource "null_resource" "nullmount" {
  depends_on = [aws_volume_attachment.attatch_ebs]
  connection {
      type = "ssh"
      user = "ec2-user"
      private_key = tls_private_key.web-key.private_key_pem
      host = aws_instance.web-instance[0].public_ip
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4 /dev/xvdh",
      "sudo mount /dev/xvdh /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/Paoli99/certi-website.git  /var/www/html"
    ]
  }
}

locals {
  s3_origin_id = "s3-origin"
}

resource "aws_s3_bucket" "website-bucket" {
  bucket = "website-bucket"
  acl = "public-read-write"
  //region = "us-east-1a"

  versioning {
    enabled = true
  }

  tags = {
    Name = "website-bucket"
    Environment = "PROD_UPB"
  }

  provisioner "local-exec" {
      command = "git clone https://github.com/Paoli99/certi-website.git web-server-image"
  }
}

resource "aws_s3_bucket_public_access_block" "public_storage" {
  depends_on = [aws_s3_bucket.website-bucket]
  bucket = "website-bucket"
  block_public_acls = false
  block_public_policy = false 
}

/* resource "aws_s3_bucket_object" "website-object" {
  depends_on = [aws_s3_bucket.website-bucket]
  bucket = "website-bucket"
  acl = "public-read-write"
  key = "HIMYM.jpg"
  source = "web-server-image/HIMYM.jpg"
} */

resource "aws_cloudfront_distribution" "web-cloudfront" {
  depends_on = [aws_s3_bucket_object.website-object]
  origin{ 
      domain_name = aws_s3_bucket.website-bucket.bucket
      origin_id = local.s3_origin_id
  }
  enabled = true 
  default_cache_behavior {
        allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
        cached_methods = ["GET", "HEAD"]
        target_origin_id = local.s3_origin_id

        forwarded_values {
            query_string = false
        
            cookies {
               forward = "none"
            }
        }
        viewer_protocol_policy = "allow-all"
        min_ttl = 0
        default_ttl = 3600
        max_ttl = 86400
    }

    restrictions {
        geo_restriction {
           restriction_type = "none"
        }
    }

     viewer_certificate {
        cloudfront_default_certificate = true

    } 
}

/* resource "null_resource" "Write_Image" {
    depends_on = [aws_cloudfront_distribution.web-cloudfront]
    connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.web-key.private_key_pem
    host     = aws_instance.web-instance[0].public_ip
     }
  provisioner "remote-exec" {
        inline = [
            "sudo su << EOF",
                    "echo \"<img src='http://${aws_cloudfront_distribution.web-cloudfront.domain_name}/${aws_s3_bucket_object.website-object.key}' width='300' height='380'>\" >>/var/www/html/index.html",
                    "echo \"</body>\" >>/var/www/html/index.html",
                    "echo \"</html>\" >>/var/www/html/index.html",
                    "EOF",    
        ]
  }

}
 */

resource "null_resource" "result" {
    //depends_on = [null_resource.nullmount]
    provisioner "local-exec" {
    command = "echo The website has been deployed successfully and >> result.txt  && echo the IP of the website is  ${aws_instance.web-instance[0].public_ip} >>result.txt"
  }
}

resource "null_resource" "running_the_website" {
    //depends_on = [null_resource.Write_Image]
    provisioner "local-exec" {
    command = "start chrome ${aws_instance.web-instance[0].public_ip}"
  }
}