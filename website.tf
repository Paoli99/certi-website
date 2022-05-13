provider "aws" {
    region = "us-west-1"    
    access_key = ""
    secret_key = ""
    //version = "= 2.17.0"
}


resource "aws_vpc" "my_website_vpc" {
    cidr_block = "10.0.0.0/16"
    tags = {
        Name = "website_vpc"
    }
}


resource "aws_subnet" "website_subnet" {
    tags = {
        Name = "web_subnet"
    }
    vpc_id = aws_vpc.my_website_vpc.id
    cidr_block = "10.0.1.0/24"
    map_public_ip_on_launch = true
    depends_on= [aws_vpc.my_website_vpc]
    
}


resource "aws_route_table" "web_rt" {
    tags = {
        Name = "website_routetable"
       
    }
     vpc_id = aws_vpc.my_website_vpc.id
}


resource "aws_route_table_association" "App_Route_Association" {
  subnet_id      = aws_subnet.website_subnet.id 
  route_table_id = aws_route_table.web_rt.id
}


resource "aws_internet_gateway" "web_igw" {
    tags = {
        Name = "web_igw"  
    }
     vpc_id = aws_vpc.my_website_vpc.id
     depends_on = [aws_vpc.my_website_vpc]
}

resource "aws_route" "default_route" {
  route_table_id = aws_route_table.web_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.web_igw.id
}


resource "aws_security_group" "web_sg" {
    name = "web_sg"
    description = "Allow Web inbound traffic"
    vpc_id = aws_vpc.my_website_vpc.id
    ingress  {
        protocol = "tcp"
        from_port = 80
        to_port  = 80
        cidr_blocks = ["0.0.0.0/0"]
    }

    ingress  {
        protocol = "tcp"
        from_port = 22
        to_port  = 22
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress  {
        protocol = "-1"
        from_port = 0
        to_port  = 0
        cidr_blocks = ["0.0.0.0/0"]
    }
}


resource "tls_private_key" "Web-Key" {
  algorithm = "RSA"
}


resource "aws_key_pair" "web-instance-key" {
  key_name   = "Web-key"
  public_key = tls_private_key.Web-Key.public_key_openssh
}


resource "local_file" "Web-Key" {
    content     = tls_private_key.Web-Key.private_key_pem 
    filename = "Web-Key.pem"
}


resource "aws_instance" "Web" {
    ami = "ami-02541b8af977f6cdd"
    instance_type = "t2.micro"
    tags = {
        Name = "WebServer"
    }
    count =1
    subnet_id = aws_subnet.website_subnet.id 
    key_name = "Web-key"
    security_groups = [aws_security_group.web_sg.id]

    provisioner "remote-exec" {
    connection {
        type = "ssh"
        user = "ec2-user"
        private_key = tls_private_key.Web-Key.private_key_pem
        host = aws_instance.Web[0].public_ip
    }    
    inline = [
       "sudo yum install httpd  php git -y",
       "sudo systemctl restart httpd",
       "sudo systemctl enable httpd",
    ]
  }

}


resource "aws_ebs_volume" "web-ebs" {
  availability_zone = aws_instance.Web[0].availability_zone
  size              = 1
  tags = {
    Name = "ebsvol"
  }
}


resource "aws_volume_attachment" "attach_ebs" {
  depends_on = [aws_ebs_volume.web-ebs]
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.web-ebs.id
  instance_id = aws_instance.Web[0].id
  force_detach = true
}


resource "null_resource" "nullmount" {
  depends_on = [aws_volume_attachment.attach_ebs]
    connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.Web-Key.private_key_pem
    host     = aws_instance.Web[0].public_ip
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


 resource "aws_s3_bucket" "websitemockservice" {
  bucket = "websitemockservice"
  acl    = "public-read-write"
  //region = "us-east-1"

  versioning {
    enabled = true
  }

  tags = {
    Name = "websitemockservice"
    Environment = "PROD_UPB"
  }

} 

resource "aws_s3_bucket_public_access_block" "public_storage" {
 depends_on = [aws_s3_bucket.websitemockservice]
 bucket = "websitemockservice"
 block_public_acls = false
 block_public_policy = false
}

resource "aws_cloudfront_distribution" "web-cloudfront" {
    //depends_on = [ aws_s3_bucket_object.Object1]
    origin {
        domain_name = aws_s3_bucket.websitemockservice.bucket_regional_domain_name
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

resource "null_resource" "Write_Image" {
    depends_on = [aws_cloudfront_distribution.web-cloudfront]
    connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.Web-Key.private_key_pem
    host     = aws_instance.Web[0].public_ip
     }
  provisioner "remote-exec" {
        inline = [
            "sudo su << EOF",
                    "echo \"</body>\" >>/var/www/html/index.html",
                    "echo \"</html>\" >>/var/www/html/index.html",
                    "EOF",    
        ]
  }

}

resource "null_resource" "result" {
    depends_on = [null_resource.nullmount]
    provisioner "local-exec" {
    command = "echo The website has been deployed successfully and >> result.txt  && echo the IP of the website is  ${aws_instance.Web[0].public_ip} >>result.txt"
  }
}


resource "null_resource" "running_the_website" {
    depends_on = [null_resource.Write_Image]
    provisioner "local-exec" {
    command = "start chrome ${aws_instance.Web[0].public_ip}"
  }
}
