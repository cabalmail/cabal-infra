# Github

You must [sign up for a Github account](https://github.com/signup) if you don't already have one.

After signing up and logging in, [fork this repository](https://docs.github.com/en/get-started/quickstart/fork-a-repo). (Do not try to create infrastucture directly from the original repo.) Note the URL of the repository. You will need it later.

Create two [secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets):

1. Log in to your Github account.
2. Navigate to the newly forked repository.
3. From the repository, navigate to Settings, and then Secrets. This should show any Actions secrets by default. If you see any other secrets settings, navigiate to Actions secrets.
4. Create two secrets, one called AWS_ACCESS_KEY_ID and the other called AWS_SECRET_ACCESS_KEY. Store the key ID and secret that you created in the [AWS setup](./aws.md) in step 10.

Later, you will also create a third secret called AWS_S3_BUCKET.
