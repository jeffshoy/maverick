import subprocess
import time
import logging

# Configure logging
logging.basicConfig(
    filename="script_debug.log",
    level=logging.DEBUG,
    format="%(asctime)s - %(levelname)s - %(message)s"
)

def run_script(script_path):
    """
    Runs a Linux shell script, captures output, and logs errors for debugging.
    """
    try:
        logging.info(f"Starting script: {script_path}")

        # Start the script execution
        start_time = time.time()
        process = subprocess.Popen(
            ["bash", script_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        # Read output in real-time
        for line in iter(process.stdout.readline, ""):
            print(line, end="")  # Print to console
            logging.info(f"OUTPUT: {line.strip()}")  # Log output

        # Capture errors
        stderr_output = process.stderr.read()
        if stderr_output:
            logging.error(f"ERROR: {stderr_output.strip()}")

        # Wait for process to complete
        process.wait()
        end_time = time.time()
        execution_time = end_time - start_time

        # Check exit status
        if process.returncode == 0:
            logging.info(f"Script completed successfully in {execution_time:.2f} seconds.")
        else:
            logging.error(f"Script failed with exit code {process.returncode} in {execution_time:.2f} seconds.")

    except Exception as e:
        logging.exception(f"Exception occurred: {e}")

# Example Usage
if __name__ == "__main__":
    script_path = "/path/to/your/script.sh"  # Change this to your script
    run_script(script_path)
