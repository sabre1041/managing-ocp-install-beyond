#!/usr/bin/python3

from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer
import httplib
import SocketServer
import json
import ssl
import urllib
import os

# AWX connection and job template details:
AWX_HOST = os.environ.get('TOWER_HOST')
AWX_PORT = os.getenv('TOWER_PORT', 443)
AWX_USER = os.environ.get('TOWER_USER')
AWX_PASSWORD = os.environ.get('TOWER_PASSWORD')
AWX_TEMPLATE = os.environ.get('TOWER_JOB_TEMPLATE')

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        print "Received Post Request"
        # Read and parse the request body:
        length = int(self.headers['Content-Length'])
        body = self.rfile.read(length)
        body = body.decode("utf-8")
        body = json.loads(body)
        print("Alert manager request:\n%s" % self.indent(body))

        # Send an empty response:
        self.send_response(200)
        self.end_headers()

        # Process all the alerts:
        alerts = body["alerts"]
        for alert in alerts:
            self.process_alert(alert)

    def process_alert(self, alert):
        # Request the authentication token:
        token = self.get_token()

        # Build the query to find the job template:
        query = {
            "name": AWX_TEMPLATE
        }
        query = urllib.urlencode(query)

        # Send the request to find the job template:
        response = self.send_request(
            method='GET',
            path="/api/v2/job_templates/?%s" % query,
            token=token,
        )

        # Get the identifier of the job template:
        template_id = response["results"][0]["id"]

        # Send the request to launch the job template, including all the labels
        # of the alert as extra variables for the AWX job template:
        extra_vars = alert["labels"]
        extra_vars = json.dumps(extra_vars)
        self.send_request(
            method='POST',
            path="/api/v2/job_templates/%s/launch/" % template_id,
            token=token,
            body={
              "extra_vars": extra_vars,
            },
        )

    def get_token(self):
        response = self.send_request(
            method='POST',
            path="/api/v2/authtoken/",
            body={
                "username": AWX_USER,
                "password": AWX_PASSWORD,
            },
        )
        return response["token"]

    def send_request(self, method, path, token=None, body=None):
        print("AWX method: %s" % method)
        print("AWX path: %s" % path)
        if token is not None:
            print("AWX token: %s" % token)
        if body is not None:
            print("AWX request:\n%s" % self.indent(body))
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
            context.verify_mode = ssl.CERT_NONE
            context.check_hostname = False
            connection = httplib.HTTPSConnection(
                host=AWX_HOST,
                port=AWX_PORT,
                context=context,
            )
            body = json.dumps(body)
            body = body.encode("utf-8")
            headers = {
                "Content-type": "application/json",
                "Accept": "application/json",
            }
            if token is not None:
                headers["Authorization"] = "Token %s" % token
            print(headers)
            connection.request(
                method=method,
                url=path,
                headers=headers,
                body=body,
            )
            response = connection.getresponse()
            body = response.read()
            body = body.decode("utf-8")
            body = json.loads(body)
            print("AWX response:\n%s" % self.indent(body))
            return body
        finally:
            connection.close()

    def indent(self, data):
        return json.dumps(data, indent=2)

# Start the web server:
server_address = ('', 8080)
httpd = HTTPServer(server_address, Handler)
print 'Starting httpd...'
httpd.serve_forever()

