package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func required(name string) string {
	value := os.Getenv(name)
	if value == "" {
		panic(name + " is required")
	}
	return value
}

func main() {
	client := s3.NewFromConfig(aws.Config{
		Region: "auto",
		Credentials: credentials.NewStaticCredentialsProvider(
			required("CK_LOCAL_ARCHIVE_ACCESS_KEY_ID"),
			required("CK_LOCAL_ARCHIVE_SECRET_ACCESS_KEY"),
			"",
		),
		HTTPClient: &http.Client{Timeout: 10 * time.Second},
	}, func(options *s3.Options) {
		options.BaseEndpoint = aws.String(required("CK_LOCAL_ARCHIVE_ENDPOINT"))
		options.UsePathStyle = true
	})
	_, err := client.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:       aws.String(required("CK_LOCAL_ARCHIVE_BUCKET")),
		Key:          aws.String("packs/424242.pack"),
		Body:         bytes.NewReader([]byte("0123456789tracking-sdk-archive")),
		ContentType:  aws.String("application/octet-stream"),
		CacheControl: aws.String("public,max-age=31536000,immutable"),
	})
	if err != nil {
		panic(err)
	}
	fmt.Println("uploaded")
}
